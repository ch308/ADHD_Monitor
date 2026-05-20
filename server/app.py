import sqlite3
import os
import json
import re
import threading
import time
import hashlib
import hmac
import secrets
from collections import deque
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, Response
from flask_cors import CORS
from openai import OpenAI

app = Flask(__name__)
# 开启跨域支持，确保安卓手机 App 可以顺利访问
CORS(app)

# Kimi 使用 OpenAI SDK 兼容接口；请在服务器环境变量中配置 MOONSHOT_API_KEY
client = OpenAI(
    api_key=os.getenv("MOONSHOT_API_KEY", "你的_MOONSHOT_API_KEY"),
    base_url=os.getenv("MOONSHOT_BASE_URL", "https://api.moonshot.cn/v1"),
)

# 内存：各 child_id 最新状态（GET /webhook 按 X-Child-Id 返回）
latest_child_status = {}

# --- 数据库初始化 ---
def init_db():
    """初始化 SQLite 数据库，创建存储表"""
    conn = sqlite3.connect('adhd_data.db')
    cursor = conn.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS heart_rate_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME,
            bpm REAL,
            is_alert INTEGER,
            child_id INTEGER NOT NULL DEFAULT 1
        )
    ''')
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS parent_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME,
            bpm REAL,
            observation TEXT,
            ai_advice TEXT,
            condition_type TEXT,
            child_id INTEGER NOT NULL DEFAULT 1
        )
    ''')
    # 旧库补列
    cursor.execute("PRAGMA table_info(parent_logs)")
    cols = [row[1] for row in cursor.fetchall()]
    if "condition_type" not in cols:
        cursor.execute("ALTER TABLE parent_logs ADD COLUMN condition_type TEXT")
    if "child_id" not in cols:
        cursor.execute("ALTER TABLE parent_logs ADD COLUMN child_id INTEGER NOT NULL DEFAULT 1")

    cursor.execute("PRAGMA table_info(heart_rate_history)")
    hcols = [row[1] for row in cursor.fetchall()]
    if "child_id" not in hcols:
        cursor.execute(
            "ALTER TABLE heart_rate_history ADD COLUMN child_id INTEGER NOT NULL DEFAULT 1"
        )

    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS weekly_reports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            week_start TEXT NOT NULL,
            week_end TEXT NOT NULL,
            summary TEXT NOT NULL,
            digest_json TEXT,
            created_at TEXT NOT NULL,
            child_id INTEGER NOT NULL DEFAULT 1,
            UNIQUE(week_start, child_id)
        )
        """
    )
    # 旧 weekly_reports 仅 UNIQUE(week_start) 时迁移为按孩子区分
    cursor.execute("PRAGMA table_info(weekly_reports)")
    wcols = [row[1] for row in cursor.fetchall()]
    if wcols and "child_id" not in wcols:
        cursor.execute(
            """
            CREATE TABLE weekly_reports_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                week_start TEXT NOT NULL,
                week_end TEXT NOT NULL,
                summary TEXT NOT NULL,
                digest_json TEXT,
                created_at TEXT NOT NULL,
                child_id INTEGER NOT NULL DEFAULT 1,
                UNIQUE(week_start, child_id)
            )
            """
        )
        cursor.execute(
            """
            INSERT INTO weekly_reports_new
            (week_start, week_end, summary, digest_json, created_at, child_id)
            SELECT week_start, week_end, summary, digest_json, created_at, 1
            FROM weekly_reports
            """
        )
        cursor.execute("DROP TABLE weekly_reports")
        cursor.execute("ALTER TABLE weekly_reports_new RENAME TO weekly_reports")

    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            display_name TEXT,
            created_at TEXT NOT NULL
        )
        """
    )
    # 全库唯一登录名（大小写不敏感），避免多家庭注册时出现 Dad / dad 两条账号
    try:
        cursor.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_lower
            ON users(lower(username))
            """
        )
    except sqlite3.OperationalError as e:
        print(
            "⚠️ 无法创建用户名大小写唯一索引（可能存在仅大小写不同的重复账号）：",
            e,
        )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS children (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nickname TEXT NOT NULL,
            created_at TEXT NOT NULL,
            created_by_user_id INTEGER NOT NULL,
            FOREIGN KEY (created_by_user_id) REFERENCES users(id)
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS child_members (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            child_id INTEGER NOT NULL,
            role TEXT NOT NULL DEFAULT 'guardian',
            created_at TEXT NOT NULL,
            UNIQUE(user_id, child_id),
            FOREIGN KEY (user_id) REFERENCES users(id),
            FOREIGN KEY (child_id) REFERENCES children(id)
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL UNIQUE,
            user_id INTEGER NOT NULL,
            expires_at TEXT NOT NULL,
            FOREIGN KEY (user_id) REFERENCES users(id)
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS device_bindings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mac_address TEXT NOT NULL UNIQUE,
            child_id INTEGER NOT NULL,
            bound_by_user_id INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (child_id) REFERENCES children(id),
            FOREIGN KEY (bound_by_user_id) REFERENCES users(id)
        )
        """
    )
    # ESP32-S3 灯环设备：device_id 由 efuse MAC 派生（Wireless_GetDeviceId）
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS esp32_devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL UNIQUE,
            kind TEXT,
            child_id INTEGER,
            bound_by_user_id INTEGER,
            first_seen_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            FOREIGN KEY (child_id) REFERENCES children(id),
            FOREIGN KEY (bound_by_user_id) REFERENCES users(id)
        )
        """
    )
    conn.commit()
    conn.close()
    print("✅ 数据库 adhd_data.db 初始化成功")

# 启动时执行初始化
init_db()


def _default_status():
    return {"bpm": 0, "alert": False, "timestamp": ""}


def _hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt.encode("ascii"),
        120000,
    ).hex()
    return f"{salt}${dk}"


_USERNAME_RE = re.compile(r"^[a-z0-9_]{3,40}$")


def _normalize_username(raw: str) -> str:
    return (raw or "").strip().lower()


def _verify_password(password: str, stored: str) -> bool:
    try:
        salt, hexhash = stored.split("$", 1)
        dk = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            salt.encode("ascii"),
            120000,
        ).hex()
        return hmac.compare_digest(dk, hexhash)
    except ValueError:
        return False


def _parse_bearer_token():
    h = (request.headers.get("Authorization") or "").strip()
    if h.lower().startswith("bearer "):
        return h[7:].strip()
    return ""


def _auth_user_from_token(cursor, token: str):
    if not token:
        return None
    cursor.execute(
        """
        SELECT u.id, u.username, u.display_name
        FROM sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token = ? AND s.expires_at > ?
        """,
        (token, datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
    )
    row = cursor.fetchone()
    if not row:
        return None
    return {"id": row[0], "username": row[1], "display_name": row[2]}


def _get_request_user():
    """当前请求已登录用户，或 None（未带合法 token）。"""
    tok = _parse_bearer_token()
    if not tok:
        return None
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    user = _auth_user_from_token(cursor, tok)
    conn.close()
    return user


def _parse_child_id_param():
    raw = (request.headers.get("X-Child-Id") or request.args.get("child_id") or "1").strip()
    try:
        return max(1, int(raw))
    except ValueError:
        return 1


def _user_can_access_child(cursor, user_id: int, child_id: int) -> bool:
    cursor.execute(
        "SELECT 1 FROM child_members WHERE user_id = ? AND child_id = ?",
        (user_id, child_id),
    )
    return cursor.fetchone() is not None


def _resolve_child_id_for_read():
    """
    读孩子数据时的 child_id。
    未登录：仅允许 child_id=1（兼容旧设备）。
    已登录：须为孩子成员。
    """
    cid = _parse_child_id_param()
    user = _get_request_user()
    if user is None:
        if cid != 1:
            return None, (jsonify({"status": "error", "message": "login required for child_id != 1"}), 401)
        return 1, None
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    ok = _user_can_access_child(cursor, user["id"], cid)
    conn.close()
    if not ok:
        return None, (jsonify({"status": "error", "message": "forbidden for this child"}), 403)
    return cid, None


def _child_exists(cid: int) -> bool:
    """检查 children 表中是否存在该 child_id。"""
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute("SELECT 1 FROM children WHERE id = ?", (cid,))
    found = cursor.fetchone() is not None
    conn.close()
    return found


def _resolve_child_id_for_write(child_id_from_body: int):
    """
    写心率/记录的 child_id 校验：
    - 已登录用户：须为该孩子的成员。
    - 未登录（模拟器 / 硬件）：只要 child_id 在 children 表中存在即可，
      无需登录，方便多台模拟器分别向不同孩子推数据。
    """
    cid = max(1, int(child_id_from_body or 1))
    user = _get_request_user()
    if user is None:
        # 硬件/模拟器推送：child 必须已创建，否则拒绝
        if not _child_exists(cid):
            return None, (
                jsonify({"status": "error", "message": f"child_id={cid} 不存在，请先在 App 内创建孩子档案"}),
                404,
            )
        return cid, None
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    ok = _user_can_access_child(cursor, user["id"], cid)
    conn.close()
    if not ok:
        return None, (jsonify({"status": "error", "message": "forbidden for this child"}), 403)
    return cid, None


def _condition_label(condition_type):
    if condition_type == "autism":
        return "自闭症"
    return "多动症"


def _heart_avg_between(
    cursor, t_lo, t_hi, child_id, lo_exclusive=False, hi_exclusive=False
):
    """t_lo / t_hi 为 'YYYY-MM-DD HH:MM:SS'"""
    lop = ">" if lo_exclusive else ">="
    hip = "<" if hi_exclusive else "<="
    cursor.execute(
        f"""
        SELECT AVG(bpm), COUNT(*)
        FROM heart_rate_history
        WHERE child_id = ? AND timestamp {lop} ? AND timestamp {hip} ?
        """,
        (child_id, t_lo, t_hi),
    )
    row = cursor.fetchone()
    if not row or row[1] == 0:
        return None, 0
    return float(row[0]), int(row[1])


def _trend_after_advice(cursor, log_ts_str, child_id):
    """
    对比「记录提交前」与「提交后一段时间」的心率均值，粗判情绪曲线是否缓和。
    返回 (trend_code, trend_label, avg_before, avg_after, n_before, n_after)
    trend_code: improving | worsen | steady | unknown
    """
    try:
        log_dt = datetime.strptime(log_ts_str.strip(), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return "unknown", "记录时间格式异常，无法与心率曲线对比", None, None, 0, 0

    before_start = (log_dt - timedelta(minutes=15)).strftime("%Y-%m-%d %H:%M:%S")
    before_end = log_ts_str
    after_start = log_ts_str
    after_end = (log_dt + timedelta(minutes=20)).strftime("%Y-%m-%d %H:%M:%S")

    # 建议前：含记录时刻及之前 15 分钟；建议后：严格晚于记录时刻，避免同一条采样重复计入
    avg_before, n_before = _heart_avg_between(
        cursor, before_start, before_end, child_id, lo_exclusive=False, hi_exclusive=False
    )
    avg_after, n_after = _heart_avg_between(
        cursor, after_start, after_end, child_id, lo_exclusive=True, hi_exclusive=False
    )

    if n_before < 1 or n_after < 1:
        return (
            "unknown",
            "建议后心率采样不足，暂无法判断曲线是否缓和（请保持模拟器/设备持续上报）",
            avg_before,
            avg_after,
            n_before,
            n_after,
        )

    delta = avg_after - avg_before
    # 阈值：均值变化约 3 BPM 视为有方向性信号（演示场景下的经验值）
    if delta <= -3:
        return (
            "improving",
            f"建议后约 20 分钟内心率均值由 {avg_before:.0f} 降至 {avg_after:.0f}，曲线趋于缓和",
            avg_before,
            avg_after,
            n_before,
            n_after,
        )
    if delta >= 3:
        return (
            "worsen",
            f"建议后心率均值仍高于记录前（约 {avg_before:.0f} → {avg_after:.0f}），可再观察环境或休息安排",
            avg_before,
            avg_after,
            n_before,
            n_after,
        )
    return (
        "steady",
        f"建议前后心率均值变化不大（约 {avg_before:.0f} → {avg_after:.0f}），处于相对平稳区间",
        avg_before,
        avg_after,
        n_before,
        n_after,
    )


def fetch_kimi_advice(bpm, observation, condition_type):
    """按记录类型调用 Kimi：adhd=多动症，autism=自闭症"""
    if condition_type == "autism":
        system = (
            "你是面向自闭症谱系家庭的特教关怀助手，侧重感官负荷、可预期流程、"
            "简短清晰的沟通与情绪共调，缓解家长焦虑并给出可立刻执行的一小步。"
        )
        prompt = (
            f"假设孩子属于自闭症谱系（非合并诊断场景下也请按谱系支持思路回应）。"
            f"当前心率约 {bpm}，家长观察到：「{observation}」。"
            f"请结合可能的感官、沟通或环境触发，给家长一句具体、温暖、可操作的现场干预建议。"
            f"要求：50字以内，语气鼓励，不要套话与免责声明。"
        )
    else:
        system = (
            "你是面向 ADHD（多动症）家庭的特教关怀助手，侧重执行功能、注意力与冲动、"
            "身体调节与正向行为支持，缓解家长焦虑并给出可立刻执行的一小步。"
        )
        prompt = (
            f"假设孩子以 ADHD（注意缺陷多动障碍）特点为主。"
            f"当前心率约 {bpm}，家长观察到：「{observation}」。"
            f"请从注意力、冲动、身体躁动或任务挫败等角度，给家长一句具体、温暖、可操作的现场干预建议。"
            f"要求：50字以内，语气鼓励，不要套话与免责声明。"
        )

    try:
        response = client.chat.completions.create(
            model="moonshot-v1-8k",
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": prompt}
            ],
            temperature=0.7
        )
        return response.choices[0].message.content
    except Exception as e:
        print(f"Kimi API 错误: {e}")
        if condition_type == "autism":
            return "建议家长先放慢节奏，降低环境刺激，用简短句子陪伴，观察孩子是否需要安静或感官安抚。"
        return "建议家长先帮孩子把任务拆小、降低干扰，温和引导深呼吸或短暂休息，再一起继续。"

@app.route('/webhook', methods=['POST', 'GET'])
def handle_webhook():
    global latest_child_status

    if request.method == 'POST':
        incoming_data = request.json
        if not incoming_data:
            return jsonify({"status": "error", "message": "No data"}), 400

        try:
            raw_cid = incoming_data.get("child_id", 1)
            child_id = max(1, int(raw_cid))
        except (TypeError, ValueError):
            child_id = 1

        err = _resolve_child_id_for_write(child_id)
        if err[1] is not None:
            return err[1]
        child_id = err[0]

        bpm = incoming_data.get("data", {}).get("bpm", 0)
        timestamp = incoming_data.get("data", {}).get(
            "timestamp", datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        )

        is_alert = True if bpm > 100 else False

        payload = {"bpm": bpm, "alert": is_alert, "timestamp": timestamp}
        latest_child_status[child_id] = payload

        try:
            conn = sqlite3.connect('adhd_data.db')
            cursor = conn.cursor()
            cursor.execute(
                'INSERT INTO heart_rate_history (timestamp, bpm, is_alert, child_id) VALUES (?, ?, ?, ?)',
                (timestamp, bpm, 1 if is_alert else 0, child_id),
            )
            conn.commit()
            conn.close()
        except Exception as e:
            print(f"❌ 数据库写入错误: {e}")

        status_icon = "🚨" if is_alert else "✅"
        print(f"数据入库 child={child_id} -> {timestamp} | BPM: {bpm} {status_icon}")

        return jsonify({"status": "success", "received_bpm": bpm, "child_id": child_id}), 200

    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err
    return jsonify(latest_child_status.get(cid, _default_status())), 200

@app.route('/submit_log', methods=['POST'])
def submit_log():
    """保存家长观察记录，并返回 Kimi 生成的干预建议"""
    data = request.json or {}
    raw_cid = data.get("child_id")
    if raw_cid is None:
        raw_cid = (request.headers.get("X-Child-Id") or "1").strip()
    try:
        child_id = max(1, int(raw_cid))
    except (TypeError, ValueError):
        child_id = 1

    err = _resolve_child_id_for_write(child_id)
    if err[1] is not None:
        return err[1]
    child_id = err[0]

    snap = latest_child_status.get(child_id, _default_status())
    bpm = data.get("bpm", snap.get("bpm", 0))
    observation = (data.get("observation") or "").strip()
    condition_type = (data.get("condition_type") or "").strip().lower()
    if condition_type not in ("adhd", "autism"):
        return jsonify({
            "status": "error",
            "message": "condition_type is required and must be adhd or autism",
        }), 400

    if not observation:
        return jsonify({"status": "error", "message": "observation is required"}), 400

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    advice = fetch_kimi_advice(bpm, observation, condition_type)

    try:
        conn = sqlite3.connect('adhd_data.db')
        cursor = conn.cursor()
        cursor.execute(
            'INSERT INTO parent_logs (timestamp, bpm, observation, ai_advice, condition_type, child_id) VALUES (?, ?, ?, ?, ?, ?)',
            (timestamp, bpm, observation, advice, condition_type, child_id),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"❌ 家长记录写入错误: {e}")
        return jsonify({"status": "error", "message": str(e)}), 500

    return jsonify({"advice": advice, "child_id": child_id}), 200

@app.route('/history', methods=['GET'])
def get_history():
    """供 Flutter App 调用：获取最近 20 条历史记录用于画图"""
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err
    try:
        conn = sqlite3.connect('adhd_data.db')
        cursor = conn.cursor()
        cursor.execute(
            'SELECT timestamp, bpm FROM heart_rate_history WHERE child_id = ? ORDER BY id DESC LIMIT 20',
            (cid,),
        )
        rows = cursor.fetchall()
        conn.close()

        history_list = []
        for row in reversed(rows):
            history_list.append({
                "time": row[0].split(" ")[1],
                "bpm": row[1]
            })

        return jsonify(history_list), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route("/footprint/today", methods=["GET"])
def footprint_today():
    """
    今日家长记录足迹：次数、每条观察与 AI 建议、建议前后心率粗对比。
    可选查询参数 date=YYYY-MM-DD（默认服务器当天日期）。
    """
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err

    date_str = (request.args.get("date") or "").strip()
    if date_str:
        try:
            datetime.strptime(date_str, "%Y-%m-%d")
        except ValueError:
            return jsonify({"status": "error", "message": "invalid date, use YYYY-MM-DD"}), 400
    else:
        date_str = datetime.now().strftime("%Y-%m-%d")

    prefix = f"{date_str} %"

    try:
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT id, timestamp, bpm, observation, ai_advice, condition_type
            FROM parent_logs
            WHERE child_id = ? AND timestamp LIKE ?
            ORDER BY id ASC
            """,
            (cid, prefix),
        )
        rows = cursor.fetchall()

        logs_out = []
        summary = {"improving": 0, "worsen": 0, "steady": 0, "unknown": 0}

        for row in rows:
            _id, ts, bpm, obs, advice, cond = row
            cond = (cond or "adhd").lower()
            trend_code, trend_label, avg_b, avg_a, nb, na = _trend_after_advice(
                cursor, ts, cid
            )
            summary[trend_code] = summary.get(trend_code, 0) + 1

            logs_out.append(
                {
                    "id": _id,
                    "timestamp": ts,
                    "time": ts.split(" ", 1)[-1] if " " in ts else ts,
                    "bpm": bpm,
                    "observation": obs,
                    "ai_advice": advice,
                    "condition_type": cond,
                    "condition_label": _condition_label(cond),
                    "trend_after": trend_code,
                    "trend_label": trend_label,
                    "avg_bpm_before": round(avg_b, 1) if avg_b is not None else None,
                    "avg_bpm_after": round(avg_a, 1) if avg_a is not None else None,
                    "samples_before": nb,
                    "samples_after": na,
                }
            )

        conn.close()
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

    return jsonify(
        {
            "child_id": cid,
            "date": date_str,
            "log_count": len(logs_out),
            "trend_summary": summary,
            "logs": logs_out,
        }
    ), 200


# --- AI 周报（周日夜间 Kimi 长文总结）---


def _week_monday_sunday_strings(anchor: datetime):
    """自然周：周一至周日（含）。返回 week_start_date, week_end_date 均为 YYYY-MM-DD。"""
    base = anchor.replace(hour=12, minute=0, second=0, microsecond=0)
    monday = (base - timedelta(days=base.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    sunday = monday + timedelta(days=6)
    return monday.strftime("%Y-%m-%d"), sunday.strftime("%Y-%m-%d")


def _week_sql_bounds(week_start: str, week_end: str):
    return f"{week_start} 00:00:00", f"{week_end} 23:59:59"


def _collect_week_digest(cursor, t_lo: str, t_hi: str, child_id: int):
    """聚合本周心率与家长记录，供 Kimi 与 digest_json 存档。"""
    cursor.execute(
        """
        SELECT COUNT(*), AVG(bpm), MIN(bpm), MAX(bpm), SUM(is_alert)
        FROM heart_rate_history
        WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
        """,
        (child_id, t_lo, t_hi),
    )
    hrow = cursor.fetchone()
    heart_n = int(hrow[0] or 0)
    heart_avg = float(hrow[1]) if hrow[1] is not None else None
    heart_min = float(hrow[2]) if hrow[2] is not None else None
    heart_max = float(hrow[3]) if hrow[3] is not None else None
    alert_sum = int(hrow[4] or 0)

    cursor.execute(
        """
        SELECT substr(timestamp, 1, 13) AS bucket,
               AVG(bpm) AS avgb,
               AVG(is_alert * 1.0) AS ar,
               COUNT(*) AS n
        FROM heart_rate_history
        WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
        GROUP BY bucket
        ORDER BY ar DESC, avgb DESC
        LIMIT 12
        """,
        (child_id, t_lo, t_hi),
    )
    hourly_stress = []
    for bucket, avgb, ar, n in cursor.fetchall():
        hourly_stress.append(
            {
                "bucket": bucket,
                "avg_bpm": round(float(avgb), 1) if avgb is not None else None,
                "alert_rate": round(float(ar), 3) if ar is not None else None,
                "n": int(n),
            }
        )

    cursor.execute(
        """
        SELECT date(timestamp) AS d,
               AVG(bpm) AS avgb,
               AVG(is_alert * 1.0) AS ar,
               COUNT(*) AS n
        FROM heart_rate_history
        WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
        GROUP BY d
        ORDER BY d
        """,
        (child_id, t_lo, t_hi),
    )
    daily = []
    for d, avgb, ar, n in cursor.fetchall():
        daily.append(
            {
                "date": d,
                "avg_bpm": round(float(avgb), 1) if avgb is not None else None,
                "alert_rate": round(float(ar), 3) if ar is not None else None,
                "n": int(n),
            }
        )

    cursor.execute(
        """
        SELECT timestamp, bpm, observation, ai_advice,
               COALESCE(condition_type, 'adhd') AS ctype
        FROM parent_logs
        WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
        ORDER BY timestamp DESC
        LIMIT 40
        """,
        (child_id, t_lo, t_hi),
    )
    log_rows = list(cursor.fetchall())
    log_rows.reverse()
    logs = []
    for ts, bpm, obs, adv, ctype in log_rows:
        obs_s = (obs or "")[:120]
        adv_s = (adv or "")[:160]
        logs.append(
            {
                "timestamp": ts,
                "bpm": bpm,
                "observation": obs_s,
                "ai_advice_snippet": adv_s,
                "condition_type": ctype,
                "condition_label": _condition_label(ctype.lower()),
            }
        )

    return {
        "heart_sample_count": heart_n,
        "heart_avg_bpm": round(heart_avg, 1) if heart_avg is not None else None,
        "heart_min_bpm": round(heart_min, 1) if heart_min is not None else None,
        "heart_max_bpm": round(heart_max, 1) if heart_max is not None else None,
        "heart_alert_count": alert_sum,
        "hourly_stress_ranked": hourly_stress,
        "daily_heart": daily,
        "parent_logs": logs,
    }


def _build_weekly_kimi_user_prompt(child_name: str, week_start: str, week_end: str, digest: dict) -> str:
    lines = [
        f"请根据以下「一周数据摘要」，给家长写一份中文「AI 周报」。",
        f"",
        f"【统计周期】{week_start}（周一）至 {week_end}（周日）",
        f"【孩子称呼】{child_name}（文中可直接用此称呼）",
        f"",
        f"【心率数据概览】",
        f"- 本周心率采样条数：{digest['heart_sample_count']}",
        f"- 周平均心率(BPM)：{digest.get('heart_avg_bpm')}",
        f"- 最低/最高(BPM)：{digest.get('heart_min_bpm')} / {digest.get('heart_max_bpm')}",
        f"- 采样中处于「报警心率」的次数合计：{digest.get('heart_alert_count')}",
        f"",
        f"【按小时聚合：报警比例或平均心率偏高的时段（最多列出前若干）】",
    ]
    for h in digest.get("hourly_stress_ranked") or []:
        lines.append(
            f"- {h['bucket']}时 平均心率≈{h['avg_bpm']} 报警比例≈{h['alert_rate']} 样本数={h['n']}"
        )
    if not digest.get("hourly_stress_ranked"):
        lines.append("- （该周无足够按小时聚合的心率数据）")

    lines += ["", "【按天汇总（有数据的天）】"]
    for d in digest.get("daily_heart") or []:
        lines.append(
            f"- {d['date']} 平均心率≈{d['avg_bpm']} 报警比例≈{d['alert_rate']} 样本={d['n']}"
        )
    if not digest.get("daily_heart"):
        lines.append("- （该周无按天汇总数据）")

    lines += ["", f"【家长观察与当时 AI 单次建议】共 {len(digest.get('parent_logs') or [])} 条"]
    for p in digest.get("parent_logs") or []:
        lines.append(
            f"- {p['timestamp']} [{p['condition_label']}] 心率{p['bpm']} 观察：{p['observation']}"
        )
        lines.append(f"  当时 AI 建议摘要：{p['ai_advice_snippet']}")
    if len(digest.get("parent_logs") or []) >= 40:
        lines.append("")
        lines.append("（本周家长记录较多，上文仅纳入最近 40 条；统计仍以全量数据在库为准。）")

    lines += [
        "",
        "【写作要求】",
        "1. 用自然、亲切的第二人称写给家长；不要医学诊断，不要替代就医。",
        "2. 若数据能支持，请综合心率时段与家长记录，指出「更容易紧张或焦躁」的大致时间段或场景；若证据不足请诚实说明，不要编造。",
        "3. 给出 2～4 条下周可执行的、具体的家庭支持建议（可涉及任务拆分、环境、作息、沟通方式等）。",
        "4. 可参考叙述风格（不必照抄）：例如指出某时段易焦虑、与家长记录中的活动（如作业）相呼应，并建议将任务拆成更短关卡等。",
        "5. 全文约 350～700 字，分 2～4 段，不要用 Markdown 标题符号，不要输出 JSON。",
    ]
    return "\n".join(lines)


def fetch_kimi_weekly_report(user_prompt: str) -> str:
    """调用 Kimi 生成长文周报。"""
    system = (
        "你是儿童发育与特殊教育领域的资深顾问，熟悉 ADHD 与自闭症谱系的居家与学校适应支持。"
        "你根据家长端设备采集的一周心率与家长文字记录，撰写「周报」帮助家长看见规律与下一步。"
        "语气专业、温暖、具体。严禁医学诊断与面诊替代。数据不足时要明确说明，不编造趋势。"
    )
    model = os.getenv("WEEKLY_REPORT_MODEL", "moonshot-v1-8k")
    try:
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.42,
            max_tokens=2800,
        )
        text = (response.choices[0].message.content or "").strip()
        return text
    except Exception as e:
        print(f"Kimi 周报 API 错误: {e}")
        raise


def generate_weekly_report(anchor: datetime = None, force: bool = False, child_id: int = 1):
    """
    聚合 anchor 所在自然周（周一至周日）的数据，调用 Kimi，写入 weekly_reports。
    返回 dict: week_start, week_end, summary, created_at, id, child_id
    """
    anchor = anchor or datetime.now()
    week_start, week_end = _week_monday_sunday_strings(anchor)
    t_lo, t_hi = _week_sql_bounds(week_start, week_end)
    child_name = (os.getenv("CHILD_DISPLAY_NAME") or "孩子").strip() or "孩子"

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not force:
        cursor.execute(
            "SELECT id FROM weekly_reports WHERE week_start = ? AND child_id = ?",
            (week_start, child_id),
        )
        if cursor.fetchone():
            conn.close()
            return {
                "status": "skipped",
                "message": f"本周 {week_start} 孩子{child_id} 已有周报，若需覆盖请传 force=true",
                "week_start": week_start,
                "week_end": week_end,
                "child_id": child_id,
            }

    digest = _collect_week_digest(cursor, t_lo, t_hi, child_id)
    conn.close()

    user_prompt = _build_weekly_kimi_user_prompt(
        child_name, week_start, week_end, digest
    )
    summary = fetch_kimi_weekly_report(user_prompt)
    if not summary or len(summary) < 40:
        raise RuntimeError("Kimi 返回内容过短，未写入周报表")

    created_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    digest_json = json.dumps(digest, ensure_ascii=False)

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        INSERT OR REPLACE INTO weekly_reports (week_start, week_end, summary, digest_json, created_at, child_id)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (week_start, week_end, summary, digest_json, created_at, child_id),
    )
    rid = cursor.lastrowid
    conn.commit()
    conn.close()

    return {
        "status": "ok",
        "id": rid,
        "child_id": child_id,
        "week_start": week_start,
        "week_end": week_end,
        "summary": summary,
        "created_at": created_at,
    }


def _seconds_until_next_sunday_2100(now: datetime = None) -> float:
    """距下一次「周日 21:00」的秒数（严格晚于 now）。"""
    now = now or datetime.now()
    if now.weekday() == 6:
        candidate = now.replace(hour=21, minute=0, second=0, microsecond=0)
        target = candidate if now < candidate else candidate + timedelta(days=7)
    else:
        days = 6 - now.weekday()
        sun = (now + timedelta(days=days)).replace(
            hour=21, minute=0, second=0, microsecond=0
        )
        target = sun
    return max(30.0, (target - now).total_seconds())


def _weekly_scheduler_loop():
    """守护线程：每周日 21:00 尝试生成当周周报（若已存在则跳过）。"""
    while True:
        try:
            delay = _seconds_until_next_sunday_2100()
            print(f"📅 周报调度：约 {int(delay)} 秒后执行（下次周日 21:00 窗口）")
            time.sleep(delay)
            generate_weekly_report(anchor=datetime.now(), force=False, child_id=1)
            print("✅ 周报定时任务已执行一轮")
        except Exception as e:
            print(f"❌ 周报定时任务异常: {e}")
            time.sleep(3600)


def _start_weekly_scheduler_thread():
    if os.getenv("DISABLE_WEEKLY_SCHEDULER", "").strip() in ("1", "true", "yes"):
        print("⚠️ 已禁用周报守护线程（DISABLE_WEEKLY_SCHEDULER）")
        return
    t = threading.Thread(target=_weekly_scheduler_loop, daemon=True)
    t.start()
    print("✅ 周报守护线程已启动（每周日 21:00 生成当周周报）")


def _weekly_generate_auth_ok() -> bool:
    secret = (os.getenv("WEEKLY_REPORT_SECRET") or "").strip()
    if not secret:
        return True
    got = (request.headers.get("X-Weekly-Report-Secret") or "").strip()
    return got == secret


@app.route("/weekly_report/latest", methods=["GET"])
def weekly_report_latest():
    """最近一条已存储的 AI 周报（按当前 X-Child-Id）。"""
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err
    try:
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT week_start, week_end, summary, created_at
            FROM weekly_reports
            WHERE child_id = ?
            ORDER BY created_at DESC, id DESC
            LIMIT 1
            """,
            (cid,),
        )
        row = cursor.fetchone()
        conn.close()
        if not row:
            return jsonify({"status": "empty", "message": "暂无周报"}), 404
        return jsonify(
            {
                "child_id": cid,
                "week_start": row[0],
                "week_end": row[1],
                "summary": row[2],
                "created_at": row[3],
            }
        ), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route("/weekly_report/history", methods=["GET"])
def weekly_report_history():
    """最近若干条周报列表（按当前 X-Child-Id）。"""
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err
    try:
        lim = int(request.args.get("limit") or 6)
        lim = max(1, min(lim, 24))
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT week_start, week_end, summary, created_at
            FROM weekly_reports
            WHERE child_id = ?
            ORDER BY week_start DESC
            LIMIT ?
            """,
            (cid, lim),
        )
        rows = cursor.fetchall()
        conn.close()
        out = []
        for r in rows:
            summ = r[2] or ""
            if len(summ) > 400:
                summ = summ[:400] + "…"
            out.append(
                {
                    "week_start": r[0],
                    "week_end": r[1],
                    "summary_preview": summ,
                    "created_at": r[3],
                }
            )
        return jsonify({"child_id": cid, "reports": out}), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route("/auth/register", methods=["POST"])
def auth_register():
    data = request.json or {}
    username = _normalize_username(data.get("username") or "")
    password = data.get("password") or ""
    display_name = (data.get("display_name") or username).strip() or username
    if not _USERNAME_RE.match(username):
        return jsonify(
            {
                "status": "error",
                "message": "username must be 3-40 chars: lowercase letters, digits, underscore",
            }
        ), 400
    if len(password) < 6:
        return jsonify({"status": "error", "message": "password min length 6"}), 400
    ph = _hash_password(password)
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        cursor.execute(
            "SELECT 1 FROM users WHERE lower(username) = ? LIMIT 1",
            (username,),
        )
        if cursor.fetchone():
            conn.close()
            return jsonify({"status": "error", "message": "username already exists"}), 409
        cursor.execute(
            "INSERT INTO users (username, password_hash, display_name, created_at) VALUES (?,?,?,?)",
            (username, ph, display_name, now),
        )
        uid = cursor.lastrowid
        conn.commit()
        conn.close()
    except sqlite3.IntegrityError:
        return jsonify({"status": "error", "message": "username already exists"}), 409
    return jsonify({"status": "ok", "user_id": uid, "username": username}), 200


@app.route("/auth/login", methods=["POST"])
def auth_login():
    data = request.json or {}
    username = _normalize_username(data.get("username") or "")
    password = data.get("password") or ""
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        "SELECT id, password_hash, display_name FROM users WHERE lower(username) = ?",
        (username,),
    )
    row = cursor.fetchone()
    if not row or not _verify_password(password, row[1]):
        conn.close()
        return jsonify({"status": "error", "message": "invalid credentials"}), 401
    uid = row[0]
    display_name = row[2]
    token = secrets.token_urlsafe(32)
    exp = (datetime.now() + timedelta(days=14)).strftime("%Y-%m-%d %H:%M:%S")
    cursor.execute(
        "INSERT INTO sessions (token, user_id, expires_at) VALUES (?, ?, ?)",
        (token, uid, exp),
    )
    conn.commit()
    conn.close()
    return jsonify(
        {
            "token": token,
            "user": {"id": uid, "username": username, "display_name": display_name},
        }
    ), 200


@app.route("/my/children", methods=["GET"])
def my_children_list():
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT c.id, c.nickname, m.role
        FROM children c
        JOIN child_members m ON m.child_id = c.id
        WHERE m.user_id = ?
        ORDER BY c.id ASC
        """,
        (user["id"],),
    )
    rows = cursor.fetchall()
    conn.close()
    out = [{"id": r[0], "nickname": r[1], "role": r[2]} for r in rows]
    return jsonify({"children": out}), 200


@app.route("/my/children", methods=["POST"])
def my_children_create():
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    nickname = (data.get("nickname") or "我的孩子").strip() or "我的孩子"
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        "INSERT INTO children (nickname, created_at, created_by_user_id) VALUES (?, ?, ?)",
        (nickname, now, user["id"]),
    )
    cid = cursor.lastrowid
    cursor.execute(
        """
        INSERT INTO child_members (user_id, child_id, role, created_at)
        VALUES (?, ?, ?, ?)
        """,
        (user["id"], cid, "guardian", now),
    )
    conn.commit()
    conn.close()
    return jsonify({"status": "ok", "child_id": cid, "nickname": nickname}), 200


@app.route("/my/children/<int:child_id>/members", methods=["POST"])
def my_children_add_member(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    invite_username = _normalize_username(data.get("username") or "")
    role = (data.get("role") or "family").strip() or "family"
    if len(invite_username) < 3:
        return jsonify({"status": "error", "message": "username required"}), 400
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    cursor.execute("SELECT id FROM users WHERE lower(username) = ?", (invite_username,))
    row = cursor.fetchone()
    if not row:
        conn.close()
        return jsonify({"status": "error", "message": "user not found"}), 404
    invitee_id = row[0]
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        cursor.execute(
            """
            INSERT INTO child_members (user_id, child_id, role, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (invitee_id, child_id, role, now),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        conn.close()
        return jsonify({"status": "error", "message": "already a member"}), 409
    conn.close()
    return jsonify({"status": "ok", "child_id": child_id, "username": invite_username, "role": role}), 200


@app.route("/weekly_report/generate", methods=["POST"])
def weekly_report_generate():
    """
    手动或 cron 触发生成周报。JSON 可选：date=YYYY-MM-DD（该日期所在周）、force=true。
    若设置环境变量 WEEKLY_REPORT_SECRET，则请求头需带 X-Weekly-Report-Secret。
    """
    if not _weekly_generate_auth_ok():
        return jsonify({"status": "error", "message": "Unauthorized"}), 401

    data = request.json or {}
    force = bool(data.get("force"))
    try:
        wchild = max(1, int(data.get("child_id") or 1))
    except (TypeError, ValueError):
        wchild = 1

    secret_ok = bool((os.getenv("WEEKLY_REPORT_SECRET") or "").strip()) and (
        (request.headers.get("X-Weekly-Report-Secret") or "").strip()
        == (os.getenv("WEEKLY_REPORT_SECRET") or "").strip()
    )
    if wchild != 1 and not secret_ok:
        u = _get_request_user()
        if not u:
            return jsonify({"status": "error", "message": "login required for child_id != 1"}), 401
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        ok = _user_can_access_child(cursor, u["id"], wchild)
        conn.close()
        if not ok:
            return jsonify({"status": "error", "message": "forbidden for this child"}), 403

    date_str = (data.get("date") or "").strip()
    if date_str:
        try:
            anchor = datetime.strptime(date_str, "%Y-%m-%d")
        except ValueError:
            return jsonify({"status": "error", "message": "invalid date"}), 400
    else:
        anchor = datetime.now()

    try:
        result = generate_weekly_report(anchor=anchor, force=force, child_id=wchild)
    except RuntimeError as e:
        return jsonify({"status": "error", "message": str(e)}), 502
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

    return jsonify(result), 200


# ── 手环设备绑定 ──


@app.route("/device/<mac>/binding", methods=["GET"])
def device_binding_status(mac):
    """查询手环 MAC 地址的绑定状态。"""
    mac = (mac or "").strip().upper()
    if not mac:
        return jsonify({"status": "error", "message": "mac_address required"}), 400

    user = _get_request_user()
    cid = _parse_child_id_param()

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT d.child_id, c.nickname
        FROM device_bindings d
        JOIN children c ON c.id = d.child_id
        WHERE d.mac_address = ?
        """,
        (mac,),
    )
    row = cursor.fetchone()
    conn.close()

    if not row:
        return jsonify({
            "mac_address": mac,
            "bound_child_id": None,
            "bound_child_nickname": None,
            "is_bound_to_current_child": False,
        }), 200

    bound_cid = row[0]
    bound_nickname = row[1]
    is_current = (user is not None and bound_cid == cid)

    return jsonify({
        "mac_address": mac,
        "bound_child_id": bound_cid,
        "bound_child_nickname": bound_nickname,
        "is_bound_to_current_child": is_current,
    }), 200


@app.route("/device/bind", methods=["POST"])
def device_bind():
    """将手环 MAC 绑定到指定孩子。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401

    data = request.json or {}
    mac = (data.get("mac_address") or "").strip().upper()
    if not mac:
        return jsonify({"status": "error", "message": "mac_address required"}), 400

    try:
        child_id = max(1, int(data.get("child_id") or 1))
    except (TypeError, ValueError):
        return jsonify({"status": "error", "message": "invalid child_id"}), 400

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()

    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden for this child"}), 403

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        cursor.execute(
            """
            INSERT OR REPLACE INTO device_bindings (mac_address, child_id, bound_by_user_id, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (mac, child_id, user["id"], now),
        )
        conn.commit()
    except Exception as e:
        conn.close()
        return jsonify({"status": "error", "message": str(e)}), 500
    conn.close()

    return jsonify({
        "status": "ok",
        "mac_address": mac,
        "child_id": child_id,
    }), 200


@app.route("/device/unbind", methods=["POST"])
def device_unbind():
    """解除手环 MAC 的绑定。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401

    data = request.json or {}
    mac = (data.get("mac_address") or "").strip().upper()
    if not mac:
        return jsonify({"status": "error", "message": "mac_address required"}), 400

    try:
        child_id = max(1, int(data.get("child_id") or 1))
    except (TypeError, ValueError):
        return jsonify({"status": "error", "message": "invalid child_id"}), 400

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()

    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden for this child"}), 403

    cursor.execute(
        "DELETE FROM device_bindings WHERE mac_address = ? AND child_id = ?",
        (mac, child_id),
    )
    conn.commit()
    conn.close()

    return jsonify({
        "status": "ok",
        "mac_address": mac,
        "child_id": child_id,
    }), 200


# ── ESP32-S3 设备：announce + 绑定 + 长轮询命令通道 ──
#
# 设计原则：
#   1. ESP32 上电先调 POST /device/esp32/announce 报上 device_id（无需登录），
#      服务器在 esp32_devices 表登记，便于 App 端选择并绑定到孩子。
#   2. 已登录 App 调 POST /device/esp32/bind 把 device_id 绑到 child_id 上。
#      之后只有"对该 child_id 有权限"的用户能通过 POST /device/<id>/cmd
#      推命令到这块 ESP32。
#   3. ESP32 长轮询 GET /device/<id>/cmd?wait=N：服务器在 _esp32_cmd_lock 上
#      等待，最多 N 秒；一旦有命令进 _esp32_cmd_queue[device_id] 立刻返回。
#      没有命令则返回 204 No Content，ESP32 立刻发下一轮。

_esp32_cmd_lock = threading.Condition()
# device_id -> deque[dict]
_esp32_cmd_queue: "dict[str, deque]" = {}
_ESP32_DEVICE_ID_RE = re.compile(r"^[A-F0-9]{4,32}$")


def _now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _normalize_device_id(raw: str) -> str:
    return (raw or "").strip().upper()


def _touch_esp32_device(device_id: str, kind: str | None) -> None:
    """登记/更新 esp32_devices 行，不做权限校验（announce 阶段允许匿名）。"""
    now = _now_str()
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        "SELECT id FROM esp32_devices WHERE device_id = ?",
        (device_id,),
    )
    row = cursor.fetchone()
    if row is None:
        cursor.execute(
            """
            INSERT INTO esp32_devices (device_id, kind, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?)
            """,
            (device_id, (kind or "").strip() or None, now, now),
        )
    else:
        cursor.execute(
            "UPDATE esp32_devices SET last_seen_at = ?, kind = COALESCE(NULLIF(?, ''), kind) WHERE id = ?",
            (now, (kind or "").strip(), row[0]),
        )
    conn.commit()
    conn.close()


def _get_esp32_device(device_id: str):
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT device_id, kind, child_id, bound_by_user_id, first_seen_at, last_seen_at
        FROM esp32_devices WHERE device_id = ?
        """,
        (device_id,),
    )
    row = cursor.fetchone()
    conn.close()
    if row is None:
        return None
    return {
        "device_id": row[0],
        "kind": row[1],
        "child_id": row[2],
        "bound_by_user_id": row[3],
        "first_seen_at": row[4],
        "last_seen_at": row[5],
    }


@app.route("/device/esp32/announce", methods=["POST"])
def esp32_announce():
    """ESP32 上电时调用。无需登录。

    板子刚启动（包括正常重启 / 重新配网完成 / 掉电恢复）→ 此前队列里
    残留的命令对新会话没有意义，必须丢掉，避免出现"用户重新配网完后
    灯环莫名其妙开始呼吸"这种残留命令重放问题。
    """
    data = request.json or {}
    device_id = _normalize_device_id(data.get("device_id") or "")
    if not _ESP32_DEVICE_ID_RE.match(device_id):
        return jsonify({"status": "error", "message": "invalid device_id"}), 400
    _touch_esp32_device(device_id, data.get("kind"))
    with _esp32_cmd_lock:
        dropped = _esp32_cmd_queue.pop(device_id, None)
    if dropped:
        app.logger.info(
            "esp32 announce %s dropped %d stale cmd(s)", device_id, len(dropped)
        )
    return jsonify({"status": "ok", "device_id": device_id}), 200


@app.route("/device/esp32/list", methods=["GET"])
def esp32_list():
    """App 端用：列出当前用户名下任一孩子绑定的 ESP32；同时返回未绑定的（用户可以认领）。"""
    user = _get_request_user()
    if user is None:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT e.device_id, e.kind, e.child_id, c.nickname, e.first_seen_at, e.last_seen_at
        FROM esp32_devices e
        LEFT JOIN children c ON c.id = e.child_id
        WHERE e.child_id IS NULL
           OR e.child_id IN (SELECT child_id FROM child_members WHERE user_id = ?)
        ORDER BY e.last_seen_at DESC
        """,
        (user["id"],),
    )
    rows = cursor.fetchall()
    conn.close()
    out = [
        {
            "device_id": r[0],
            "kind": r[1],
            "child_id": r[2],
            "child_nickname": r[3],
            "first_seen_at": r[4],
            "last_seen_at": r[5],
        }
        for r in rows
    ]
    return jsonify({"devices": out}), 200


@app.route("/device/esp32/bind", methods=["POST"])
def esp32_bind():
    """把 device_id 绑到指定 child_id；登录 + 该 child 的成员才能调。"""
    user = _get_request_user()
    if user is None:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    device_id = _normalize_device_id(data.get("device_id") or "")
    if not _ESP32_DEVICE_ID_RE.match(device_id):
        return jsonify({"status": "error", "message": "invalid device_id"}), 400
    try:
        child_id = max(1, int(data.get("child_id") or 0))
    except (TypeError, ValueError):
        return jsonify({"status": "error", "message": "invalid child_id"}), 400
    if child_id <= 0:
        return jsonify({"status": "error", "message": "child_id required"}), 400

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden for this child"}), 403

    now = _now_str()
    cursor.execute("SELECT id FROM esp32_devices WHERE device_id = ?", (device_id,))
    row = cursor.fetchone()
    if row is None:
        cursor.execute(
            """
            INSERT INTO esp32_devices
                (device_id, kind, child_id, bound_by_user_id, first_seen_at, last_seen_at)
            VALUES (?, NULL, ?, ?, ?, ?)
            """,
            (device_id, child_id, user["id"], now, now),
        )
    else:
        cursor.execute(
            "UPDATE esp32_devices SET child_id = ?, bound_by_user_id = ?, last_seen_at = ? WHERE id = ?",
            (child_id, user["id"], now, row[0]),
        )
    conn.commit()
    conn.close()
    return jsonify({"status": "ok", "device_id": device_id, "child_id": child_id}), 200


@app.route("/device/esp32/unbind", methods=["POST"])
def esp32_unbind():
    user = _get_request_user()
    if user is None:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    device_id = _normalize_device_id(data.get("device_id") or "")
    if not _ESP32_DEVICE_ID_RE.match(device_id):
        return jsonify({"status": "error", "message": "invalid device_id"}), 400
    info = _get_esp32_device(device_id)
    if info is None or info["child_id"] is None:
        return jsonify({"status": "ok", "device_id": device_id}), 200
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], info["child_id"]):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden for this child"}), 403
    cursor.execute(
        "UPDATE esp32_devices SET child_id = NULL, bound_by_user_id = NULL WHERE device_id = ?",
        (device_id,),
    )
    conn.commit()
    conn.close()
    return jsonify({"status": "ok", "device_id": device_id}), 200


# 允许 ESP32 端推送的命令白名单（其它会被拒，避免恶意/误用）
# reset_provisioning：让板子清掉 NVS 中的 WiFi 凭据并重启进入 BLE 配网模式，
# 用于"换 WiFi / 把灯环送给别人 / 想重新走配网流程"等场景。
_ESP32_ALLOWED_ACTIONS = {
    "breathing_start", "breathing_stop",
    "countdown_start", "countdown_stop",
    "all_off",
    "reset_provisioning",
}


def _validate_cmd_payload(action: str, payload: dict) -> tuple[bool, str]:
    if action not in _ESP32_ALLOWED_ACTIONS:
        return False, f"action '{action}' not allowed"
    if action == "breathing_start":
        cm = payload.get("cycle_ms", 8000)
        try:
            cm = int(cm)
        except (TypeError, ValueError):
            return False, "cycle_ms must be int"
        if not 1200 <= cm <= 30000:
            return False, "cycle_ms out of range (1200..30000)"
        payload["cycle_ms"] = cm
    if action == "countdown_start":
        tm = payload.get("total_ms", 10000)
        try:
            tm = int(tm)
        except (TypeError, ValueError):
            return False, "total_ms must be int"
        if not 1000 <= tm <= 600000:
            return False, "total_ms out of range (1000..600000)"
        payload["total_ms"] = tm
    return True, ""


@app.route("/device/<device_id>/cmd", methods=["GET", "POST"])
def esp32_cmd(device_id: str):
    device_id = _normalize_device_id(device_id)
    if not _ESP32_DEVICE_ID_RE.match(device_id):
        return jsonify({"status": "error", "message": "invalid device_id"}), 400

    # 推命令（来自 Flutter App）
    if request.method == "POST":
        user = _get_request_user()
        if user is None:
            return jsonify({"status": "error", "message": "unauthorized"}), 401
        info = _get_esp32_device(device_id)
        if info is None:
            return jsonify({"status": "error", "message": "device unknown"}), 404
        if info["child_id"] is None:
            return jsonify({"status": "error", "message": "device not bound"}), 409
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        if not _user_can_access_child(cursor, user["id"], info["child_id"]):
            conn.close()
            return jsonify({"status": "error", "message": "forbidden"}), 403
        conn.close()

        data = request.json or {}
        action = (data.get("action") or "").strip()
        payload = {k: v for k, v in data.items() if k != "action"}
        ok, err = _validate_cmd_payload(action, payload)
        if not ok:
            return jsonify({"status": "error", "message": err}), 400

        cmd_obj = {"action": action}
        cmd_obj.update(payload)
        with _esp32_cmd_lock:
            q = _esp32_cmd_queue.setdefault(device_id, deque())
            # reset_provisioning 是终态操作：板子收到后立即清 NVS + 重启，
            # 之前队列里堆着的灯效命令（如 breathing_start）对重启后的板子毫无意义，
            # 全部丢弃，只保留 reset_provisioning 自己。
            if action == "reset_provisioning" and len(q) > 0:
                app.logger.info(
                    "esp32 reset_provisioning for %s drops %d pending cmd(s)",
                    device_id, len(q),
                )
                q.clear()
            q.append(cmd_obj)
            _esp32_cmd_lock.notify_all()
        return jsonify({"status": "ok", "queued": cmd_obj}), 200

    # 拉命令（来自 ESP32 长轮询）—— 不需要登录，凭 device_id 路由
    _touch_esp32_device(device_id, None)
    try:
        wait_s = float(request.args.get("wait") or 25)
    except ValueError:
        wait_s = 25.0
    wait_s = max(0.0, min(wait_s, 60.0))
    deadline = time.monotonic() + wait_s

    with _esp32_cmd_lock:
        while True:
            q = _esp32_cmd_queue.get(device_id)
            if q:
                # 拿出所有积压命令一起发，ESP32 端按顺序执行
                batch = list(q)
                q.clear()
                if not batch:
                    payload = {"cmds": []}
                elif len(batch) == 1:
                    payload = batch[0]
                else:
                    payload = {"cmds": batch}
                return jsonify(payload), 200
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                # 204 No Content：ESP32 立刻发下一轮
                return Response(status=204)
            _esp32_cmd_lock.wait(timeout=remaining)


if __name__ == '__main__':
    _start_weekly_scheduler_thread()
    # 绑定 0.0.0.0 确保外网可访问，端口使用你已开放的 11760
    app.run(host='0.0.0.0', port=11760, debug=False, threaded=True)
