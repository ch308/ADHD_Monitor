import sqlite3
import os
import sys
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

try:
    from flask_sock import Sock

    _xiaozhi_sock = Sock(app)
    from xiaozhi_bridge import register_xiaozhi

    register_xiaozhi(app, _xiaozhi_sock)
except ImportError as exc:
    # 没有 flask-sock 时 /xiaozhi/ws 根本不会注册，ESP32 连上后收不到任何 TTS，
    # 星星机器人会表现为「完全没声音」。务必在运行 app 的 venv 里安装 requirements.txt。
    import sys

    msg = (
        "\n"
        "========== ADHD xiaozhi Path A: WebSocket DISABLED ==========\n"
        f"Reason: {exc}\n"
        "Fix (on the server, in the same Python env that runs app.py):\n"
        "  cd server && pip install -r requirements.txt\n"
        "Required for star-robot voice: flask-sock, simple-websocket, requests, "
        "edge-tts, opuslib, and system package: ffmpeg\n"
        "Then restart Flask / gunicorn / your process manager.\n"
        "==============================================================\n"
    )
    print(msg, file=sys.stderr)
    print("xiaozhi Path A bridge disabled (missing dependency?):", exc)

# Kimi 使用 OpenAI SDK 兼容接口；请在服务器环境变量中配置 MOONSHOT_API_KEY
_moonshot_api_key = os.getenv("MOONSHOT_API_KEY", "你的_MOONSHOT_API_KEY")
# G2: 启动时检测占位符 API Key，输出明确警告
if _moonshot_api_key == "你的_MOONSHOT_API_KEY":
    print(
        "\n"
        "========== ⚠️  MOONSHOT_API_KEY 未配置 ==========\n"
        "检测到 MOONSHOT_API_KEY 仍为默认占位符，AI 功能将全部失效。\n"
        "请在服务器环境变量中设置真实密钥，例如：\n"
        "  export MOONSHOT_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxx\n"
        "或在 ecosystem.config.js 的 env 节点中配置后重启服务。\n"
        "==================================================\n",
        file=sys.stderr,
    )

client = OpenAI(
    api_key=_moonshot_api_key,
    base_url=os.getenv("MOONSHOT_BASE_URL", "https://api.moonshot.cn/v1"),
)

# 阿里百炼 DashScope API（AI 配图功能，可选）
_dashscope_api_key = os.getenv("DASHSCOPE_API_KEY", "你的_DASHSCOPE_API_KEY")
if _dashscope_api_key == "你的_DASHSCOPE_API_KEY":
    print(
        "\n"
        "========== ⚠️  DASHSCOPE_API_KEY 未配置（可选功能）==========\n"
        "小红书 AI 配图功能未启用。如需使用，请登录 https://bailian.console.aliyun.com/ 获取 API Key 并设置：\n"
        "  export DASHSCOPE_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxx\n"
        "==========================================================\n",
        file=sys.stderr,
    )


def _moonshot_chat_model() -> str:
    """单次建议 + 星星机器人脚本等「短对话」默认模型（周报单独用 WEEKLY_REPORT_MODEL）。"""
    m = (os.getenv("MOONSHOT_CHAT_MODEL") or "kimi-k2.5").strip()
    return m or "kimi-k2.5"


def _moonshot_kimi_extra_body():
    """Kimi 扩展参数：默认关闭思考（kimi-k2.x 更快）。

    - 默认附带 ``{"thinking": {"type": "disabled"}}``，除非 ``MOONSHOT_ENABLE_THINKING=1``。
    - ``MOONSHOT_EXTRA_BODY_JSON`` 为合法 JSON 对象时，与默认值合并（后者键可覆盖前者）。
    - 兼容旧开关：``MOONSHOT_DISABLE_THINKING=0|false|no`` 等价于开启思考（不传关闭字段）。
    """
    enable_thinking = (os.getenv("MOONSHOT_ENABLE_THINKING") or "").strip().lower() in (
        "1",
        "true",
        "yes",
    )
    legacy_off = (os.getenv("MOONSHOT_DISABLE_THINKING") or "").strip().lower() in (
        "0",
        "false",
        "no",
    )
    if legacy_off:
        enable_thinking = True

    base = None if enable_thinking else {"thinking": {"type": "disabled"}}

    raw = (os.getenv("MOONSHOT_EXTRA_BODY_JSON") or "").strip()
    if not raw:
        return base

    try:
        user = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"⚠️ MOONSHOT_EXTRA_BODY_JSON 不是合法 JSON，已忽略: {e}", file=sys.stderr)
        return base

    if not isinstance(user, dict):
        return base

    if base is None:
        return user if user else None

    merged = dict(base)
    merged.update(user)
    return merged


def _kimi_chat_create(**kwargs):
    """统一走 OpenAI SDK，合并 extra_body（供 Moonshot/Kimi 非标准字段）。"""
    extra = _moonshot_kimi_extra_body()
    if extra:
        kwargs = dict(kwargs)
        existing = kwargs.get("extra_body")
        if isinstance(existing, dict):
            merged = dict(extra)
            merged.update(existing)
            kwargs["extra_body"] = merged
        else:
            kwargs["extra_body"] = extra
    return client.chat.completions.create(**kwargs)


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
        CREATE TABLE IF NOT EXISTS period_reports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            child_id INTEGER NOT NULL DEFAULT 1,
            period_type TEXT NOT NULL,
            period_start TEXT NOT NULL,
            period_end TEXT NOT NULL,
            summary TEXT NOT NULL,
            digest_json TEXT,
            created_at TEXT NOT NULL,
            UNIQUE(child_id, period_type, period_start)
        )
        """
    )
    cursor.execute(
        """
        INSERT OR IGNORE INTO period_reports
        (child_id, period_type, period_start, period_end, summary, digest_json, created_at)
        SELECT child_id, 'week', week_start, week_end, summary, digest_json, created_at
        FROM weekly_reports
        """
    )

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
    # ESP32-S3 毛绒球呼吸灯设备：device_id 由 efuse MAC 派生（Wireless_GetDeviceId）
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
          AND bpm > 0
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
        response = _kimi_chat_create(
            model=_moonshot_chat_model(),
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


def _extract_json_object(text):
    text = (text or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else None
    except Exception:
        pass
    match = re.search(r"\{.*\}", text, flags=re.S)
    if not match:
        return None
    try:
        parsed = json.loads(match.group(0))
        return parsed if isinstance(parsed, dict) else None
    except Exception:
        return None


def fetch_xiaohongshu_draft(observation, advice, condition_type, bpm=None):
    """把一条家长记录改写成可编辑的小红书树洞草稿，默认不直接发布。"""
    label = "自闭症谱系" if condition_type == "autism" else "ADHD"
    bpm_desc = "当时心率偏高" if bpm not in (None, "", 0, 0.0) else "当时孩子状态有些紧绷"
    system = (
        "你是帮助特殊儿童家长写小红书树洞帖的中文编辑。"
        "目标是保护隐私、降低诊断化表达、保留真实处境和共鸣感，方便类似情况的家长交流。"
        "不得编造学校、城市、姓名、医院、班级、具体年龄、精确时间地点等隐私信息。"
    )
    prompt = (
        "请把下面这条家长现场记录改写成一篇可编辑的小红书草稿。\n"
        f"孩子主要支持方向：{label}\n"
        f"状态背景：{bpm_desc}\n"
        f"家长原始观察：{observation}\n"
        f"当时给家长的建议摘要：{advice or '无'}\n\n"
        "要求：\n"
        "0. 【核心要求，优先级最高】文章必须以家长原始观察描述的那个具体行为情景为主线展开，"
        "   不能替换成别的情景、不能架空泛化为「孩子状态有些紧绷」之类的模糊描述；"
        "   行为动作、情绪反应、当时场景（如写作业、大叫、来回踱步等）必须保留在正文中。\n"
        "1. 只隐去可识别个人身份的隐私：不出现姓名、学校名、住址、医院名、设备型号、"
        "   精确心率数值、具体日期时间。孩子的行为本身不属于隐私，不能删除或泛化。\n"
        "2. 语气像真实家长树洞/轻吐槽/求交流，不要像医学报告，不要诊断孩子。\n"
        "3. 可以增加少量生活化描写（地点改为「家里/外出」等泛化说法），但不能编造新的敏感事实。\n"
        "4. 结尾邀请有类似经历的家长交流，可以引用建议摘要中对家长有帮助的那个思路。\n"
        "5. 返回严格 JSON：{\"title\":\"...\",\"content\":\"...\",\"tags\":[\"...\",\"...\"]}。"
    )
    try:
        response = _kimi_chat_create(
            model=_moonshot_chat_model(),
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
            temperature=0.72,
            max_tokens=900,
        )
        raw = response.choices[0].message.content
        parsed = _extract_json_object(raw)
        if parsed:
            title = str(parsed.get("title") or "").strip()
            content = str(parsed.get("content") or "").strip()
            tags_raw = parsed.get("tags") or []
            tags = [str(t).strip().lstrip("#") for t in tags_raw if str(t).strip()]
            if title and content:
                return {
                    "title": title[:80],
                    "content": content[:1200],
                    "tags": tags[:8],
                }
    except Exception as e:
        print(f"Kimi 小红书草稿生成错误: {e}")

    fallback_title = "今天又被孩子的状态拉扯了一下"
    fallback_content = (
        "今天想来这里树洞一下。孩子刚才明显有些紧绷，我也差点跟着着急起来。"
        "后来我试着先把声音放轻，把眼前的事拆成很小的一步，先陪孩子缓一缓。"
        "养育这样的孩子，很多时候不是不爱，也不是不努力，而是真的需要一边摸索一边稳住自己。"
        "有没有类似情况的家长？你们通常会怎么陪孩子度过这种时刻，想听听大家的经验。"
    )
    return {
        "title": fallback_title,
        "content": fallback_content,
        "tags": ["育儿树洞", "特殊儿童陪伴", "家长互助"],
    }


def fetch_kimi_child_script(observation, advice, condition_type):
    """生成"星星机器人对孩子说的话"。

    `fetch_kimi_advice` 是给家长看的 50 字干预提示；这里是给 ESP32 星星机器人
    放给孩子听的开场白：以"我"称呼自己（机器人），第二人称称呼孩子，
    针对家长刚刚记录的那条具体行为切入，引导孩子说出感受。

    返回 80～140 字之间的口语化中文（2～3 句），方便 edge-tts 一次合成、
    不会因为太长而让 BLE/WS 链路超时。失败时返回基于行为关键词的兜底文案，
    保证一定有内容播给孩子。
    """
    # 第二人称硬约束：家长记录是第三人称（"她/他在写作业"），但这段话是要直接
    # 外放给孩子本人听的，必须以"你"称呼对方，否则机器人会冷冰冰地像在描述他人。
    second_person_rule = (
        '【称呼硬规则，绝对优先】你正在直接对一个孩子说话；'
        '对话对象就是面前这个孩子，必须用"你"称呼，绝不能用"她/他/她们/他们/'
        '这孩子/那个孩子/小朋友/那小朋友/这小子"等第三人称指代；'
        '凡是家长观察里出现的"她/他/孩子"都要在你输出时改写为"你"。'
        '示例：家长写"她在写作业但发脾气"，对孩子要说"你刚才写作业的时候有点发脾气"，'
        '不能说"她刚才在写作业"。'
    )
    identity_prefix = "我是星星守护者。"
    if condition_type == "autism":
        system = (
            "你是星星守护者——一个陪伴自闭症谱系孩子的口语伙伴。语气安静、平稳、可预期，"
            "句子短而具体，避免比喻和情绪词；你正在跟一个小朋友直接对话（外放给孩子听）。\n"
            + second_person_rule
        )
    else:
        system = (
            "你是星星守护者——一个陪伴 ADHD（多动症）孩子的口语伙伴。语气温暖、轻松、"
            "不评判，会用具体动作而不是抽象命令；你正在跟一个小朋友直接对话（外放给孩子听）。\n"
            + second_person_rule
        )
    prompt = (
        f'家长刚刚记录了这条观察（注意：里面"她/他/孩子"指的就是你正在对话的孩子，'
        f'你输出时必须改写成"你"）：「{observation}」。'
        f"Kimi 给家长的现场建议是：「{advice}」（只供你参考，不要在跟孩子说话时复述）。"
        "\n请你（星星守护者）直接对孩子说话，开启一段关于这个具体行为的对话："
        '\n1) 第一句必须先表明身份："我是星星守护者。"，后续对话不要再重复自我介绍；'
        "\n2) 接着温柔地点出你注意到了什么（用孩子能听懂的具体说法，"
        '  以"你刚才/你现在……"开头，**不能**出现"她/他/孩子"等第三人称指代）；'
        "\n3) 再邀请孩子说说当时的感受或想法，给一个明确的提问；"
        "\n4) 可选给一个孩子能立刻做的小动作（深呼吸、喝口水、抱一下自己等），降低紧张。"
        "\n要求："
        "\n- 全文 80～140 字，2～3 句中文口语；"
        "\n- 不要说'家长'、'记录'、'报告'、'多动症'、'自闭症'等家长视角词；"
        "\n- 不要医疗建议、不要免责声明、不要 emoji；"
        "\n- 直接输出对孩子说的那段话，不要前缀；"
        '\n- 输出里不允许出现"她/他/她们/他们"，全部用"你"。'
    )
    try:
        response = _kimi_chat_create(
            model=_moonshot_chat_model(),
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
            temperature=0.8,
            max_tokens=300,
        )
        text = (response.choices[0].message.content or "").strip()
        # 去掉 Kimi 偶尔会带的开场引号或 markdown 标记
        text = text.strip("「」\"' \n")
        # 固件 `Protocol::SendWakeWordDetected` 是裸字符串拼 JSON，没做转义；
        # 给孩子听的开场白只要包含 ASCII " / \ / 换行，就会把发上去的 JSON 弄崩。
        # 这里把这几类字符全部替换成中文等价或空格，TTS 听起来不变。
        text = (
            text.replace("\\", "")
                .replace('"', "")
                .replace("\r", " ")
                .replace("\n", " ")
        )
        # 折叠重复空格，避免多个换行变成一串空格
        while "  " in text:
            text = text.replace("  ", " ")
        if text:
            if not text.startswith(identity_prefix):
                text = identity_prefix + text
            return text[:400]
    except Exception as e:
        print(f"Kimi 子脚本生成错误: {e}")
    # 兜底：不要把家长第三人称观察原文拼进来（"她在写作业…"会让机器人显得在
    # 描述别人）。统一用泛化的、对孩子说话的第二人称模板，保证称呼对。
    if condition_type == "autism":
        return (
            identity_prefix +
            "我刚才注意到你好像有点不舒服。"
            "你愿意告诉我，那时候你心里在想什么、是什么感觉吗？"
            "我们也可以一起慢慢做三次深呼吸，等你准备好再说话。"
        )
    return (
        identity_prefix +
        "我刚才看到你了——是不是有什么让你心里不太舒服的地方？"
        "你愿意慢慢告诉我刚才发生了什么吗？我们也可以先一起做三次深呼吸。"
    )

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
    log_id = None

    try:
        conn = sqlite3.connect('adhd_data.db')
        cursor = conn.cursor()
        cursor.execute(
            'INSERT INTO parent_logs (timestamp, bpm, observation, ai_advice, condition_type, child_id) VALUES (?, ?, ?, ?, ?, ?)',
            (timestamp, bpm, observation, advice, condition_type, child_id),
        )
        log_id = cursor.lastrowid
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"❌ 家长记录写入错误: {e}")
        return jsonify({"status": "error", "message": str(e)}), 500

    try:
        _enqueue_xiaozhi_for_child(child_id, observation, advice, condition_type)
    except Exception as e:
        app.logger.warning("xiaozhi enqueue after submit_log: %s", e)

    return jsonify({"advice": advice, "child_id": child_id, "log_id": log_id}), 200


@app.route('/share/xiaohongshu_draft', methods=['POST'])
def xiaohongshu_draft():
    """生成脱敏的小红书树洞草稿；只返回草稿，不代替家长发布。"""
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err

    data = request.json or {}
    observation = (data.get("observation") or "").strip()
    advice = (data.get("advice") or "").strip()
    condition_type = (data.get("condition_type") or "").strip().lower()
    bpm = data.get("bpm")

    log_id = data.get("log_id")
    if log_id is not None:
        try:
            conn = sqlite3.connect("adhd_data.db")
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT bpm, observation, ai_advice, condition_type
                FROM parent_logs
                WHERE id = ? AND child_id = ?
                """,
                (int(log_id), cid),
            )
            row = cursor.fetchone()
            conn.close()
            if row:
                bpm, observation, advice, condition_type = row
        except Exception as e:
            return jsonify({"status": "error", "message": str(e)}), 500

    condition_type = (condition_type or "adhd").lower()
    if condition_type not in ("adhd", "autism"):
        return jsonify({
            "status": "error",
            "message": "condition_type is required and must be adhd or autism",
        }), 400
    if not observation:
        return jsonify({"status": "error", "message": "observation is required"}), 400

    draft = fetch_xiaohongshu_draft(observation, advice, condition_type, bpm=bpm)
    return jsonify({
        "status": "success",
        "child_id": cid,
        "draft": draft,
        "privacy_notice": "草稿已尽量脱敏，但发布前仍建议家长再次检查姓名、学校、住址、医院等隐私信息。",
    }), 200


def _generate_image_prompt(observation, advice, condition_type):
    """用 Kimi 根据草稿内容生成适合 Flux 模型的英文图像提示词。"""
    label = "autism spectrum" if condition_type == "autism" else "ADHD"
    system = (
        "You are an expert at writing Flux / Stable Diffusion image generation prompts "
        "for warm parenting illustrations on Chinese social media (Xiaohongshu). "
        "Return ONLY the prompt text, no explanation, no quotes."
    )
    prompt = (
        f"Create a Flux image generation prompt for a warm illustration to accompany "
        f"a Xiaohongshu parenting post about raising a child with {label}.\n"
        f"Parent's observation (for context only, do NOT include identifiable details): {observation[:200]}\n\n"
        "Requirements:\n"
        "- Style: soft watercolor illustration, warm pastel palette (peach, lavender, sage green)\n"
        "- Scene: parent and young child in a cozy home, nurturing and tender moment\n"
        "- Mood: hopeful, warm, gentle — not medical, not clinical\n"
        "- NO text, NO faces shown in detail, NO medical equipment\n"
        "- Vertical 3:4 portrait composition\n"
        "- Safe for all ages, suitable for public social media\n"
        "Return ONLY the English prompt, 40–80 words."
    )
    try:
        response = _kimi_chat_create(
            model=_moonshot_chat_model(),
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
            temperature=0.7,
            max_tokens=150,
        )
        img_prompt = (response.choices[0].message.content or "").strip().strip('"\'')
        if img_prompt:
            return img_prompt
    except Exception as e:
        print(f"Kimi 图像提示词生成错误: {e}")
    return (
        "Warm watercolor illustration of a loving parent gently sitting beside a young child "
        "at home, soft peach and lavender tones, window light, cozy atmosphere, "
        "hopeful and tender mood, no faces visible, vertical portrait composition"
    )


def _call_dashscope_image(prompt: str) -> str:
    """调用阿里百炼（DashScope）通义万象异步生成图像，返回 base64 字符串（PNG）。"""
    import requests as req_lib
    import base64
    import time

    api_url = "https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis"
    auth_headers = {"Authorization": f"Bearer {_dashscope_api_key}"}
    submit_headers = {
        **auth_headers,
        "Content-Type": "application/json",
        "X-DashScope-Async": "enable",
    }
    payload = {
        "model": "wanx2.1-t2i-turbo",
        "input": {
            "prompt": prompt,
            "negative_prompt": "低质量，模糊，文字，水印，签名，人物面部特写，医疗设备，恐怖，暗色",
        },
        "parameters": {
            "size": "768*1024",
            "n": 1,
            "style": "<watercolor>",
        },
    }

    # Step 1: 提交异步任务
    resp = req_lib.post(api_url, json=payload, headers=submit_headers, timeout=30)
    resp.raise_for_status()
    task_data = resp.json()
    task_id = task_data.get("output", {}).get("task_id")
    if not task_id:
        raise ValueError(f"百炼未返回 task_id：{task_data}")

    # Step 2: 轮询结果（最多 30 次 × 3 秒 = 90 秒）
    poll_url = f"https://dashscope.aliyuncs.com/api/v1/tasks/{task_id}"
    for _ in range(30):
        time.sleep(3)
        poll = req_lib.get(poll_url, headers=auth_headers, timeout=15)
        poll.raise_for_status()
        output = poll.json().get("output", {})
        status = output.get("task_status", "")

        if status == "SUCCEEDED":
            results = output.get("results", [])
            if not results:
                raise ValueError("百炼任务成功但无图像结果")
            img_url = results[0].get("url")
            if not img_url:
                raise ValueError("百炼未返回图像 URL")
            img_resp = req_lib.get(img_url, timeout=30)
            img_resp.raise_for_status()
            return base64.b64encode(img_resp.content).decode("utf-8")

        if status == "FAILED":
            code = output.get("code", "")
            msg = output.get("message", "未知错误")
            raise ValueError(f"百炼图像生成失败: {code} {msg}")
        # PENDING / RUNNING 继续等待

    raise TimeoutError("百炼图像生成超时，90 秒内未完成")


@app.route('/share/generate_image', methods=['POST'])
def generate_image():
    """为小红书草稿 AI 生成配图，返回 base64 PNG。

    POST body（JSON）与 /share/xiaohongshu_draft 相同：
      log_id（可选）/ observation / advice / condition_type
    """
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err

    if _dashscope_api_key == "你的_DASHSCOPE_API_KEY":
        return jsonify({
            "status": "error",
            "message": "配图功能未配置：请在服务器设置环境变量 DASHSCOPE_API_KEY",
        }), 503

    data = request.json or {}
    observation = (data.get("observation") or "").strip()
    advice = (data.get("advice") or "").strip()
    condition_type = (data.get("condition_type") or "adhd").strip().lower()

    # 如果传了 log_id，从数据库补全字段
    log_id = data.get("log_id")
    if log_id is not None:
        try:
            conn = sqlite3.connect("adhd_data.db")
            cursor = conn.cursor()
            cursor.execute(
                "SELECT observation, ai_advice, condition_type "
                "FROM parent_logs WHERE id = ? AND child_id = ?",
                (int(log_id), cid),
            )
            row = cursor.fetchone()
            conn.close()
            if row:
                observation, advice, condition_type = row
        except Exception:
            pass  # 退化到请求体字段

    if not observation:
        return jsonify({"status": "error", "message": "observation is required"}), 400

    try:
        img_prompt = _generate_image_prompt(observation, advice, condition_type)
        img_b64 = _call_dashscope_image(img_prompt)
        return jsonify({
            "status": "success",
            "image_base64": img_b64,
            "prompt_used": img_prompt,
        }), 200
    except Exception as e:
        print(f"配图生成错误: {e}")
        return jsonify({
            "status": "error",
            "message": "配图生成失败，请稍后重试",
        }), 500


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


# --- AI 周/月/年周期报告（家长主动生成，已生成后只查看）---

_PERIOD_LABELS = {
    "week": "周报",
    "month": "月报",
    "year": "年报",
}

_PERIOD_RANGE_LABELS = {
    "week": "一周",
    "month": "一个月",
    "year": "一年",
}


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


def _month_start_end_strings(anchor: datetime):
    base = anchor.replace(day=1, hour=12, minute=0, second=0, microsecond=0)
    if base.month == 12:
        next_month = base.replace(year=base.year + 1, month=1)
    else:
        next_month = base.replace(month=base.month + 1)
    end = next_month - timedelta(days=1)
    return base.strftime("%Y-%m-%d"), end.strftime("%Y-%m-%d")


def _year_start_end_strings(anchor: datetime):
    start = anchor.replace(month=1, day=1, hour=12, minute=0, second=0, microsecond=0)
    end = anchor.replace(month=12, day=31, hour=12, minute=0, second=0, microsecond=0)
    return start.strftime("%Y-%m-%d"), end.strftime("%Y-%m-%d")


def _period_start_end_strings(period_type: str, anchor: datetime):
    if period_type == "week":
        return _week_monday_sunday_strings(anchor)
    if period_type == "month":
        return _month_start_end_strings(anchor)
    if period_type == "year":
        return _year_start_end_strings(anchor)
    raise ValueError("period_type must be week, month or year")


def _period_sql_bounds(period_start: str, period_end: str):
    return f"{period_start} 00:00:00", f"{period_end} 23:59:59"


def _period_has_ended(period_end: str, now: datetime = None) -> bool:
    now = now or datetime.now()
    end_dt = datetime.strptime(f"{period_end} 23:59:59", "%Y-%m-%d %H:%M:%S")
    return now > end_dt


def _latest_completed_anchor(period_type: str, now: datetime = None) -> datetime:
    now = now or datetime.now()
    if period_type == "week":
        return now - timedelta(days=now.weekday() + 1)
    if period_type == "month":
        first_this_month = now.replace(day=1, hour=12, minute=0, second=0, microsecond=0)
        return first_this_month - timedelta(days=1)
    if period_type == "year":
        first_this_year = now.replace(month=1, day=1, hour=12, minute=0, second=0, microsecond=0)
        return first_this_year - timedelta(days=1)
    raise ValueError("period_type must be week, month or year")


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


def _build_period_kimi_user_prompt(
    period_type: str,
    child_name: str,
    period_start: str,
    period_end: str,
    digest: dict,
) -> str:
    report_label = _PERIOD_LABELS.get(period_type, "报告")
    range_label = _PERIOD_RANGE_LABELS.get(period_type, "一段时间")
    suggestion_hint = {
        "week": "给出 2～4 条下周可执行的具体家庭支持建议。",
        "month": "总结本月反复出现的场景、时段或任务类型，给出 3～5 条下月可执行的支持策略。",
        "year": "关注长期变化、家庭支持节奏与下一年度重点，不要被单次事件带偏，给出 3～5 条年度支持建议。",
    }.get(period_type, "给出具体、可执行的家庭支持建议。")
    length_hint = {
        "week": "全文约 350～700 字，分 2～4 段",
        "month": "全文约 500～900 字，分 3～5 段",
        "year": "全文约 700～1200 字，分 4～6 段",
    }.get(period_type, "全文分段自然")

    lines = [
        f"请根据以下「{range_label}数据摘要」，给家长写一份中文「AI {report_label}」。",
        "",
        f"【统计周期】{period_start} 至 {period_end}",
        f"【孩子称呼】{child_name}（文中可直接用此称呼）",
        "",
        "【心率数据概览】",
        f"- 采样条数：{digest['heart_sample_count']}",
        f"- 平均心率(BPM)：{digest.get('heart_avg_bpm')}",
        f"- 最低/最高(BPM)：{digest.get('heart_min_bpm')} / {digest.get('heart_max_bpm')}",
        f"- 采样中处于「报警心率」的次数合计：{digest.get('heart_alert_count')}",
        "",
        "【按小时聚合：报警比例或平均心率偏高的时段（最多列出前若干）】",
    ]
    for h in digest.get("hourly_stress_ranked") or []:
        lines.append(
            f"- {h['bucket']}时 平均心率≈{h['avg_bpm']} 报警比例≈{h['alert_rate']} 样本数={h['n']}"
        )
    if not digest.get("hourly_stress_ranked"):
        lines.append("- （该周期无足够按小时聚合的心率数据）")

    lines += ["", "【按天汇总（有数据的天）】"]
    for d in digest.get("daily_heart") or []:
        lines.append(
            f"- {d['date']} 平均心率≈{d['avg_bpm']} 报警比例≈{d['alert_rate']} 样本={d['n']}"
        )
    if not digest.get("daily_heart"):
        lines.append("- （该周期无按天汇总数据）")

    logs = digest.get("parent_logs") or []
    lines += ["", f"【家长观察与当时 AI 单次建议】共 {len(logs)} 条（最多纳入近期代表性记录）"]
    for p in logs:
        lines.append(
            f"- {p['timestamp']} [{p['condition_label']}] 心率{p['bpm']} 观察：{p['observation']}"
        )
        lines.append(f"  当时 AI 建议摘要：{p['ai_advice_snippet']}")

    lines += [
        "",
        "【写作要求】",
        "1. 用自然、亲切的第二人称写给家长；不要医学诊断，不要替代就医。",
        "2. 若数据能支持，请综合心率时段与家长记录，指出更容易紧张或焦躁的大致时间段或场景；若证据不足请诚实说明，不要编造。",
        f"3. {suggestion_hint}",
        "4. 对 ADHD / 自闭症谱系相关支持保持温和、具体、非标签化表达。",
        f"5. {length_hint}，不要用 Markdown 标题符号，不要输出 JSON。",
    ]
    return "\n".join(lines)


def fetch_kimi_weekly_report(user_prompt: str) -> str:
    """调用 Kimi 生成长文周报。"""
    system = (
        "你是儿童发育与特殊教育领域的资深顾问，熟悉 ADHD 与自闭症谱系的居家与学校适应支持。"
        "你根据家长端设备采集的一周心率与家长文字记录，撰写「周报」帮助家长看见规律与下一步。"
        "语气专业、温暖、具体。严禁医学诊断与面诊替代。数据不足时要明确说明，不编造趋势。"
    )
    model = (os.getenv("WEEKLY_REPORT_MODEL") or "kimi-k2.5").strip() or "kimi-k2.5"
    try:
        response = _kimi_chat_create(
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


def fetch_kimi_period_report(period_type: str, user_prompt: str) -> str:
    """调用 Kimi 生成周/月/年周期报告。"""
    report_label = _PERIOD_LABELS.get(period_type, "报告")
    system = (
        "你是儿童发育与特殊教育领域的资深顾问，熟悉 ADHD 与自闭症谱系的居家与学校适应支持。"
        f"你根据家长端设备采集的心率与家长文字记录，撰写「{report_label}」帮助家长看见规律与下一步。"
        "语气专业、温暖、具体。严禁医学诊断与面诊替代。数据不足时要明确说明，不编造趋势。"
    )
    model = (
        os.getenv("PERIOD_REPORT_MODEL")
        or os.getenv("WEEKLY_REPORT_MODEL")
        or "kimi-k2.5"
    ).strip() or "kimi-k2.5"
    max_tokens = {"week": 2800, "month": 3200, "year": 4000}.get(period_type, 2800)
    try:
        response = _kimi_chat_create(
            model=model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user_prompt},
            ],
            temperature=0.42,
            max_tokens=max_tokens,
        )
        return (response.choices[0].message.content or "").strip()
    except Exception as e:
        print(f"Kimi {report_label} API 错误: {e}")
        raise RuntimeError(f"Kimi API 调用失败（{type(e).__name__}）：{e}")


def generate_period_report(
    period_type: str,
    anchor: datetime = None,
    force: bool = False,
    child_id: int = 1,
):
    """
    为指定孩子生成已结束周期的周/月/年报告。
    同一 child_id + period_type + period_start 只生成一次；已存在则直接返回已有报告。
    """
    period_type = (period_type or "").strip().lower()
    if period_type not in _PERIOD_LABELS:
        raise ValueError("period_type must be week, month or year")

    anchor = anchor or datetime.now()
    period_start, period_end = _period_start_end_strings(period_type, anchor)
    if not _period_has_ended(period_end):
        return {
            "status": "not_ready",
            "message": f"{_PERIOD_LABELS[period_type]}对应周期尚未结束，暂不生成正式报告",
            "child_id": child_id,
            "period_type": period_type,
            "period_start": period_start,
            "period_end": period_end,
        }

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not force:
        cursor.execute(
            """
            SELECT id, summary, created_at
            FROM period_reports
            WHERE child_id = ? AND period_type = ? AND period_start = ?
            LIMIT 1
            """,
            (child_id, period_type, period_start),
        )
        row = cursor.fetchone()
        if row:
            conn.close()
            return {
                "status": "exists",
                "id": row[0],
                "child_id": child_id,
                "period_type": period_type,
                "period_label": _PERIOD_LABELS[period_type],
                "period_start": period_start,
                "period_end": period_end,
                "summary": row[1],
                "created_at": row[2],
            }

    t_lo, t_hi = _period_sql_bounds(period_start, period_end)
    digest = _collect_week_digest(cursor, t_lo, t_hi, child_id)
    conn.close()

    child_name = (os.getenv("CHILD_DISPLAY_NAME") or "孩子").strip() or "孩子"
    user_prompt = _build_period_kimi_user_prompt(
        period_type, child_name, period_start, period_end, digest
    )
    summary = fetch_kimi_period_report(period_type, user_prompt)
    if not summary or len(summary) < 40:
        raise RuntimeError("Kimi 返回内容过短，未写入报告表")

    created_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    digest_json = json.dumps(digest, ensure_ascii=False)

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        INSERT OR REPLACE INTO period_reports
        (child_id, period_type, period_start, period_end, summary, digest_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (child_id, period_type, period_start, period_end, summary, digest_json, created_at),
    )
    rid = cursor.lastrowid
    # 兼容旧 weekly_report/* 接口与旧表。
    if period_type == "week":
        cursor.execute(
            """
            INSERT OR REPLACE INTO weekly_reports
            (week_start, week_end, summary, digest_json, created_at, child_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (period_start, period_end, summary, digest_json, created_at, child_id),
        )
    conn.commit()
    conn.close()

    return {
        "status": "created",
        "id": rid,
        "child_id": child_id,
        "period_type": period_type,
        "period_label": _PERIOD_LABELS[period_type],
        "period_start": period_start,
        "period_end": period_end,
        "summary": summary,
        "created_at": created_at,
    }


def generate_weekly_report(anchor: datetime = None, force: bool = False, child_id: int = 1):
    """
    兼容旧调用：聚合 anchor 所在自然周（周一至周日）的数据，调用 Kimi，写入报告表。
    返回 dict: week_start, week_end, summary, created_at, id, child_id
    """
    result = generate_period_report(
        "week", anchor=anchor, force=force, child_id=child_id
    )
    result["week_start"] = result.get("period_start")
    result["week_end"] = result.get("period_end")
    return result


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


def _report_payload(row, include_digest=False):
    if not row:
        return None
    rid, child_id, period_type, period_start, period_end, summary, created_at, digest_raw = row
    result = {
        "id": rid,
        "child_id": child_id,
        "period_type": period_type,
        "period_label": _PERIOD_LABELS.get(period_type, "报告"),
        "period_start": period_start,
        "period_end": period_end,
        "summary": summary,
        "created_at": created_at,
    }
    if include_digest and digest_raw:
        try:
            result["digest"] = json.loads(digest_raw)
        except (json.JSONDecodeError, TypeError):
            pass
    return result


@app.route("/reports/status", methods=["GET"])
def reports_status():
    """返回当前周期进度 + 上个已结束周期的状态，供前端渲染卡片。"""
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err
    period_type = (request.args.get("period_type") or "week").strip().lower()
    if period_type not in _PERIOD_LABELS:
        return jsonify({"status": "error", "message": "invalid period_type"}), 400

    now = datetime.now()
    # 当前进行中的周期
    cur_start, cur_end = _period_start_end_strings(period_type, now)
    cur_end_dt = datetime.strptime(f"{cur_end} 23:59:59", "%Y-%m-%d %H:%M:%S")
    days_remaining = max(0, (cur_end_dt - now).days)

    t_lo, t_hi = _period_sql_bounds(cur_start, cur_end)
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()

    cursor.execute(
        "SELECT COUNT(DISTINCT date(timestamp)) FROM heart_rate_history WHERE child_id=? AND timestamp>=? AND timestamp<=? AND bpm>0",
        (cid, t_lo, t_hi),
    )
    days_collected = cursor.fetchone()[0] or 0
    cursor.execute(
        "SELECT COUNT(*) FROM parent_logs WHERE child_id=? AND timestamp>=? AND timestamp<=?",
        (cid, t_lo, t_hi),
    )
    log_count = cursor.fetchone()[0] or 0

    current_period = {
        "start": cur_start,
        "end": cur_end,
        "status": "in_progress",
        "days_collected": days_collected,
        "log_count": log_count,
        "days_remaining": days_remaining,
    }

    # 上一个已结束的周期
    last_anchor = _latest_completed_anchor(period_type, now)
    last_start, last_end = _period_start_end_strings(period_type, last_anchor)

    cursor.execute(
        "SELECT id FROM period_reports WHERE child_id=? AND period_type=? AND period_start=? LIMIT 1",
        (cid, period_type, last_start),
    )
    existing = cursor.fetchone()

    if existing:
        last_status = "generated"
        last_report_id = existing[0]
    else:
        lt_lo, lt_hi = _period_sql_bounds(last_start, last_end)
        cursor.execute(
            "SELECT COUNT(*) FROM heart_rate_history WHERE child_id=? AND timestamp>=? AND timestamp<=? AND bpm>0",
            (cid, lt_lo, lt_hi),
        )
        has_data = (cursor.fetchone()[0] or 0) > 0
        cursor.execute(
            "SELECT COUNT(*) FROM parent_logs WHERE child_id=? AND timestamp>=? AND timestamp<=?",
            (cid, lt_lo, lt_hi),
        )
        has_logs = (cursor.fetchone()[0] or 0) > 0
        if has_data or has_logs:
            last_status = "ready"
        else:
            last_status = "no_data"
        last_report_id = None

    conn.close()

    last_period = {
        "start": last_start,
        "end": last_end,
        "status": last_status,
        "report_id": last_report_id,
    }

    return jsonify({
        "child_id": cid,
        "period_type": period_type,
        "period_label": _PERIOD_LABELS[period_type],
        "current_period": current_period,
        "last_period": last_period,
    }), 200


@app.route("/reports/latest", methods=["GET"])
def reports_latest():
    """获取当前孩子最近一份周/月/年报告。"""
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err
    period_type = (request.args.get("period_type") or "week").strip().lower()
    if period_type not in _PERIOD_LABELS:
        return jsonify({"status": "error", "message": "invalid period_type"}), 400
    try:
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT id, child_id, period_type, period_start, period_end, summary, created_at, digest_json
            FROM period_reports
            WHERE child_id = ? AND period_type = ?
            ORDER BY period_start DESC, id DESC
            LIMIT 1
            """,
            (cid, period_type),
        )
        row = cursor.fetchone()
        conn.close()
        if not row:
            return jsonify({"status": "empty", "message": "暂无报告"}), 404
        return jsonify(_report_payload(row, include_digest=True)), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route("/reports/history", methods=["GET"])
def reports_history():
    """获取当前孩子的周/月/年历史报告列表。"""
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err
    period_type = (request.args.get("period_type") or "week").strip().lower()
    if period_type not in _PERIOD_LABELS:
        return jsonify({"status": "error", "message": "invalid period_type"}), 400
    try:
        lim = int(request.args.get("limit") or 12)
        lim = max(1, min(lim, 60))
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT id, child_id, period_type, period_start, period_end, summary, created_at, digest_json
            FROM period_reports
            WHERE child_id = ? AND period_type = ?
            ORDER BY period_start DESC
            LIMIT ?
            """,
            (cid, period_type, lim),
        )
        rows = cursor.fetchall()
        conn.close()
        reports = []
        for row in rows:
            item = _report_payload(row, include_digest=False)
            preview = item["summary"] or ""
            item["summary_preview"] = preview[:120] + ("…" if len(preview) > 120 else "")
            item.pop("summary", None)
            reports.append(item)
        return jsonify({"child_id": cid, "period_type": period_type, "reports": reports}), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route("/reports/<int:report_id>", methods=["GET"])
def reports_detail(report_id):
    """查看当前孩子的一份完整周期报告。"""
    cid, err = _resolve_child_id_for_read()
    if err is not None:
        return err
    try:
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT id, child_id, period_type, period_start, period_end, summary, created_at, digest_json
            FROM period_reports
            WHERE id = ? AND child_id = ?
            """,
            (report_id, cid),
        )
        row = cursor.fetchone()
        conn.close()
        if not row:
            return jsonify({"status": "empty", "message": "报告不存在"}), 404
        return jsonify(_report_payload(row, include_digest=True)), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route("/reports/generate", methods=["POST"])
def reports_generate():
    """
    家长主动生成最近一个已结束的周/月/年报告。
    相同 child_id + period_type + period_start 已存在时直接返回已有报告，不重复调用 Kimi。
    """
    data = request.json or {}
    period_type = (data.get("period_type") or "week").strip().lower()
    if period_type not in _PERIOD_LABELS:
        return jsonify({"status": "error", "message": "invalid period_type"}), 400

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

    date_str = (data.get("date") or "").strip()
    if date_str:
        try:
            anchor = datetime.strptime(date_str, "%Y-%m-%d")
        except ValueError:
            return jsonify({"status": "error", "message": "invalid date"}), 400
    else:
        anchor = _latest_completed_anchor(period_type)

    try:
        result = generate_period_report(
            period_type, anchor=anchor, force=False, child_id=child_id
        )
    except RuntimeError as e:
        return jsonify({"status": "error", "message": str(e)}), 502
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500
    return jsonify(result), 200


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
    s = (raw or "").strip().upper()
    return s.replace(":", "").replace("-", "")


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


def _xiaozhi_device_ids_for_child(child_id: int) -> list[str]:
    """挑出该孩子绑定的 xiaozhi 星星机器人 device_id 列表。

    用户名下两类设备**绝对不能搞混**：

      * 毛绒球 `ESP32-S3-LCD-1.47B`：固件 announce 写 `kind='esp32-s3-lcd-1.47B'`，
        Flutter 端 bind 时不带 kind。它走 LED 呼吸命令，**不能**收到 `xiaozhi_invoke_chat`。
      * 星星机器人 `xiaozhi-esp32-2.2.4`：固件 announce 写 `kind='xiaozhi'`，
        Flutter 端 bind 时也写 `kind='xiaozhi'`。这才是我们要 TTS 的对象。

    选择策略（按优先级）：
      1) 严格：`kind LIKE '%xiaozhi%'` —— 99% 的情况落在这里。
      2) 仅当严格命中为 0 行时，回退到 `kind IS NULL` 的"裸 bind"行。这种行
         只可能出现在「Flutter 已 bind 但设备从未 announce 过」的极端情况下，
         不会含毛绒球（毛绒球只要正常上电就一定有 `esp32-s3-lcd-...` 字面值）。
      3) 含 `lcd` / `s3-lcd` / `plush` 等毛绒球家族字面值的行 **永远不会** 被
         当成 xiaozhi 目标——即便 Flutter 误把毛绒球 bind 时给了 kind='xiaozhi'，
         只要它 announce 过一次，kind 就会被 announce 的字面值覆盖（见
         `_touch_esp32_device` 的 COALESCE 逻辑），下一次行为推送就自然过滤掉。
    """
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT device_id, kind FROM esp32_devices
        WHERE child_id = ?
        ORDER BY last_seen_at DESC
        """,
        (child_id,),
    )
    rows = cursor.fetchall()
    conn.close()

    if not rows:
        app.logger.warning(
            "xiaozhi target lookup: no esp32_devices rows for child_id=%s "
            "(check Flutter bindEsp32 + DB esp32_devices.child_id)",
            child_id,
        )
        return []

    # 已知的"绝对不是 xiaozhi"的 kind 关键词 —— 命中即排除，绝不回退。
    NON_XIAOZHI_HINTS = ("lcd", "plush", "毛绒")

    def _is_plush(kind_val: str | None) -> bool:
        if not kind_val:
            return False
        k = str(kind_val).lower()
        return any(hint in k for hint in NON_XIAOZHI_HINTS)

    strict = [r[0] for r in rows if r[1] and "xiaozhi" in str(r[1]).lower()]
    if strict:
        return strict

    # 仅在严格无命中时，回退到「绑定了但 announce 从未上送 kind」的行；明确
    # 已写为毛绒球家族字面值的行不会被纳入。
    relaxed = [
        r[0] for r in rows
        if (r[1] is None or str(r[1]).strip() == "") and not _is_plush(r[1])
    ]
    if relaxed:
        app.logger.warning(
            "xiaozhi target lookup: no strict kind=xiaozhi match for child_id=%s; "
            "falling back to %d device(s) with NULL kind: %s (all rows=%s). "
            "If you actually have a xiaozhi bound, power-cycle it once so its "
            "announce writes kind='xiaozhi'.",
            child_id, len(relaxed), relaxed,
            [(r[0], r[1]) for r in rows],
        )
        return relaxed

    # 一行都没匹配，但确实有绑定 —— 99% 是只绑了毛绒球还没绑星星机器人。
    app.logger.warning(
        "xiaozhi target lookup: child_id=%s has %d bound device(s) but NONE "
        "look like a xiaozhi robot. rows=%s. Use '星星机器人配网' in Flutter "
        "to bind a xiaozhi, then re-record the behavior.",
        child_id, len(rows), [(r[0], r[1]) for r in rows],
    )
    return []


def _enqueue_xiaozhi_for_child(child_id: int, observation: str, advice: str, condition_type: str = "") -> None:
    """家长记录一条行为 → 触发星星机器人主动跟孩子开口讲这件事。

    完整链路：
      1. 这里调 `fetch_kimi_child_script` 让 Kimi 写出针对该具体行为的开场白
         （第一人称，第二人称，80–140 字中文口语，专门给孩子听）。
      2. 把开场白 stash 进 `_xinvoke_hints[device_id]`，同时往
         `_esp32_cmd_queue[device_id]` 推一条 `xiaozhi_invoke_chat`。
      3. ESP32 长轮询拿到命令 → `WakeWordInvoke(opening_line)` → 打开 WS →
         发 `listen state=detect text=<opening_line>` 给服务器。
      4. 服务器 `XiaozhiConn._reply_turn` 识别"主动开场"那一轮（user_text 与
         hint_opening 完全一致），跳过 Kimi，直接 edge-tts 合成 opus 推回去。
      5. 星星机器人外放，孩子听到一段针对自己刚才行为的话。

    家长连记多条 → 我们覆盖前一条 hint 并清空旧 cmd queue：让机器人始终讲
    最新一次记录，避免堆积成"讲完上条再讲这条"的连环开场，对孩子很奇怪。
    """
    ids = _xiaozhi_device_ids_for_child(child_id)
    if not ids:
        app.logger.warning(
            "xiaozhi enqueue SKIPPED: child_id=%s has no bound xiaozhi devices. "
            "Use Flutter '星星机器人配网' to bind, or check /diag/xiaozhi/%s.",
            child_id, child_id,
        )
        return
    from xiaozhi_bridge import stash_xinvoke_hint

    # 1) Kimi 生成针对该行为的"对孩子说的话"。env override 仅用于离线 / 调试，
    #    线上正常路径走 Kimi。
    override = (os.getenv("XIAOZHI_DEFAULT_OPENING") or "").strip()
    if override:
        opening = override
    else:
        try:
            opening = fetch_kimi_child_script(observation, advice, condition_type or "")
        except Exception as e:
            app.logger.warning("fetch_kimi_child_script failed: %s", e)
            opening = (
                "我刚才注意到了一件让你有点不舒服的事。"
                "你愿意跟我说说当时心里是什么感觉吗？"
            )
    opening = (opening or "").strip()[:500]
    # 防御性清洗：固件 `Protocol::SendWakeWordDetected` 把 opening 裸拼进
    # listen state=detect JSON，没做转义；env 覆盖路径里如果有 " / \ / 换行
    # 也会直接把 WS 帧弄成无效 JSON 让服务器断开。这一步对 Kimi 输出和 env
    # 输入一视同仁。
    opening = (
        opening.replace("\\", "").replace('"', "").replace("\r", " ").replace("\n", " ")
    )
    while "  " in opening:
        opening = opening.replace("  ", " ")

    # 2) hint_context 给 Kimi 在后续 turn（孩子真的开口回应时）用作背景。
    #    这一轮主动开场跳过 Kimi，所以 context 主要给"孩子说话→机器人答"使用。
    ctx_lines = [f"家长观察记录：{observation}"]
    if advice:
        ctx_lines.append(f"Kimi 给家长的建议摘要：{advice}")
    if condition_type:
        label = "自闭症谱系" if condition_type == "autism" else "ADHD（多动症）"
        ctx_lines.append(f"孩子主要表现倾向：{label}（来源：家长本次记录的 condition_type）。")
    ctx = "\n".join(ctx_lines)

    cmd_obj = {
        "action": "xiaozhi_invoke_chat",
        "opening_line": opening,
        "context": ctx[:8000],
    }
    with _esp32_cmd_lock:
        for did in ids:
            stash_xinvoke_hint(did, cmd_obj["opening_line"], cmd_obj["context"])
            q = _esp32_cmd_queue.setdefault(did, deque())
            # 清空该设备此前还没被消费的旧主动命令——只保留这次最新的。
            for _ in range(len(q)):
                old = q[0]
                if isinstance(old, dict) and old.get("action") == "xiaozhi_invoke_chat":
                    q.popleft()
                else:
                    q.rotate(-1)
            q.append(dict(cmd_obj))
        _esp32_cmd_lock.notify_all()
    app.logger.info(
        "xiaozhi enqueue: child=%s targets=%s opening_len=%d ctx_len=%d",
        child_id, ids, len(opening), len(ctx),
    )


@app.route("/device/esp32/announce", methods=["POST"])
def esp32_announce():
    """ESP32 上电时调用。无需登录。

    板子刚启动（包括正常重启 / 重新配网完成 / 掉电恢复）→ 此前队列里
    残留的命令对新会话没有意义，必须丢掉，避免出现"用户重新配网完后
    毛绒球呼吸灯莫名其妙开始呼吸"这种残留命令重放问题。
    """
    data = request.json or {}
    device_id = _normalize_device_id(data.get("device_id") or "")
    if not _ESP32_DEVICE_ID_RE.match(device_id):
        return jsonify({"status": "error", "message": "invalid device_id"}), 400
    kind = data.get("kind")
    _touch_esp32_device(device_id, kind)
    app.logger.info("esp32 announce device_id=%s kind=%s", device_id, kind)
    with _esp32_cmd_lock:
        dropped = _esp32_cmd_queue.pop(device_id, None)
    if dropped:
        app.logger.info(
            "esp32 announce %s dropped %d stale cmd(s)", device_id, len(dropped)
        )
    return jsonify({"status": "ok", "device_id": device_id}), 200


@app.route("/diag/xiaozhi/<int:child_id>", methods=["GET"])
def diag_xiaozhi(child_id: int):
    """免登诊断接口：浏览器直接打开 http://<server>:11760/diag/xiaozhi/1 即可看到

    - 当前 child_id 名下 esp32_devices 全部行（device_id / kind / 时间戳）
    - `_xiaozhi_device_ids_for_child` 当前会返回的目标列表
    - `_esp32_cmd_queue` 里每个 device 的待派命令数量

    专门用于排查"submit_log 返回 200 但星星机器人没声音"。生产环境用完可以删，
    但留着也无密钥风险——只暴露设备 id 与 kind，不暴露用户表。
    """
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        "SELECT device_id, kind, child_id, first_seen_at, last_seen_at "
        "FROM esp32_devices WHERE child_id = ? ORDER BY last_seen_at DESC",
        (child_id,),
    )
    rows = [
        {
            "device_id": r[0],
            "kind": r[1],
            "child_id": r[2],
            "first_seen_at": r[3],
            "last_seen_at": r[4],
        }
        for r in cursor.fetchall()
    ]
    cursor.execute(
        "SELECT device_id, kind FROM esp32_devices "
        "WHERE child_id IS NULL ORDER BY last_seen_at DESC LIMIT 20"
    )
    unbound = [{"device_id": r[0], "kind": r[1]} for r in cursor.fetchall()]
    conn.close()

    with _esp32_cmd_lock:
        queues = {did: len(q) for did, q in _esp32_cmd_queue.items() if q}

    return jsonify({
        "child_id": child_id,
        "bound_devices": rows,
        "xiaozhi_targets": _xiaozhi_device_ids_for_child(child_id),
        "pending_cmd_queues": queues,
        "unbound_recent": unbound,
    }), 200


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

    kind = (data.get("kind") or "").strip() or None

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
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (device_id, kind, child_id, user["id"], now, now),
        )
    else:
        if kind:
            cursor.execute(
                """
                UPDATE esp32_devices
                SET child_id = ?, bound_by_user_id = ?, last_seen_at = ?, kind = ?
                WHERE id = ?
                """,
                (child_id, user["id"], now, kind, row[0]),
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
# 用于"换 WiFi / 把毛绒球呼吸灯送给别人 / 想重新走配网流程"等场景。
_ESP32_ALLOWED_ACTIONS = {
    "breathing_start", "breathing_stop",
    "countdown_start", "countdown_stop",
    "all_off",
    "reset_provisioning",
    "xiaozhi_invoke_chat",
    "xiaozhi_abort",
    "sdcard_audio_start",
    "sdcard_audio_stop",
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
        countdown_ms = payload.get("countdown_ms", 10000)
        try:
            countdown_ms = int(countdown_ms)
        except (TypeError, ValueError):
            return False, "countdown_ms must be int"
        if not 1000 <= countdown_ms <= 600000:
            return False, "countdown_ms out of range (1000..600000)"
        payload["countdown_ms"] = countdown_ms
    if action == "countdown_start":
        tm = payload.get("total_ms", 10000)
        try:
            tm = int(tm)
        except (TypeError, ValueError):
            return False, "total_ms must be int"
        if not 1000 <= tm <= 600000:
            return False, "total_ms out of range (1000..600000)"
        payload["total_ms"] = tm
    if action == "xiaozhi_invoke_chat":
        ol = (payload.get("opening_line") or "").strip()
        if len(ol) > 500:
            return False, "opening_line too long (max 500)"
        payload["opening_line"] = ol
        ctx = (payload.get("context") or "").strip()
        if len(ctx) > 8000:
            return False, "context too long (max 8000)"
        payload["context"] = ctx
    if action == "xiaozhi_abort":
        pass
    if action == "sdcard_audio_start":
        folder = (payload.get("folder") or "").strip()
        if folder not in ("432Hz", "528Hz"):
            return False, "folder must be 432Hz or 528Hz"
        payload["folder"] = folder
    if action == "sdcard_audio_stop":
        pass
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
        if action == "xiaozhi_invoke_chat":
            try:
                from xiaozhi_bridge import stash_xinvoke_hint

                stash_xinvoke_hint(
                    device_id,
                    str(cmd_obj.get("opening_line", "")),
                    str(cmd_obj.get("context", "")),
                )
            except Exception:
                pass
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
    # 周/月/年报告改为家长主动生成，避免孩子多时后台批量产生大量报告数据。
    # 绑定 0.0.0.0 确保外网可访问，端口使用你已开放的 11760
    app.run(host='0.0.0.0', port=11760, debug=False, threaded=True)
