import sqlite3
import os
import sys
import json
import re
import threading
import time
import copy
import hashlib
import hmac
import html
import secrets
import random
from collections import deque
from datetime import datetime, timedelta, timezone
from urllib.parse import quote, unquote
from flask import Flask, request, jsonify, Response, send_file, abort, has_request_context, redirect
from flask_cors import CORS
from openai import OpenAI

app = Flask(__name__)
# 开启跨域支持，确保安卓手机 App 可以顺利访问
CORS(app)


@app.route("/time", methods=["GET"])
def server_time():
    """Lightweight clock source for ESP32 firmware when xiaozhi OTA is bypassed."""
    now = datetime.now(timezone.utc)
    local = datetime.now().astimezone()
    offset = local.utcoffset() or timedelta(0)
    return jsonify(
        {
            "status": "ok",
            "timestamp_ms": int(now.timestamp() * 1000),
            "timezone_offset": int(offset.total_seconds() // 60),
        }
    )


_AUTISM_LOCAL_IMAGE_STORE = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "action")
)


def _autism_normalize_action_image_filename(fn: str) -> str:
    """修复 ESP32 直接请求中文路径时产生的 Latin-1 mojibake 文件名。"""
    if not isinstance(fn, str) or not fn:
        return ""
    if "%" in fn:
        try:
            fn = unquote(fn)
        except Exception:
            pass
    try:
        repaired = fn.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return fn
    return repaired or fn


def _autism_local_image_path_for_request(fn: str) -> str:
    path = os.path.join(_AUTISM_LOCAL_IMAGE_STORE, fn)
    if os.path.isfile(path):
        return path

    # 兼容历史中文文件名与新 ASCII 文件名之间的切换：cache key 前 8 位相同即可。
    match = re.search(r"_([0-9a-fA-F]{8})\.png$", fn)
    if not match or not os.path.isdir(_AUTISM_LOCAL_IMAGE_STORE):
        return path
    suffix = f"_{match.group(1).lower()}.png"
    try:
        for candidate in os.listdir(_AUTISM_LOCAL_IMAGE_STORE):
            if candidate.lower().endswith(suffix):
                candidate_path = os.path.join(_AUTISM_LOCAL_IMAGE_STORE, candidate)
                if os.path.isfile(candidate_path):
                    app.logger.info("action-image served by hash fallback: %r -> %r", fn, candidate)
                    return candidate_path
    except Exception as e:
        app.logger.warning("action-image hash fallback failed: %s", e)
    return path


@app.route("/autism/action-images/<fn>", methods=["GET"])
def autism_action_image_public(fn: str):
    """未配置腾讯云 COS 时，240×240 PNG 落盘于此，供星星机器人通过 HTTP 拉取。"""
    raw_fn = fn
    fn = _autism_normalize_action_image_filename(fn)
    if fn != raw_fn:
        app.logger.info("action-image repaired filename mojibake: %r -> %r", raw_fn, fn)
    if not fn or ".." in fn or "/" in fn or "\\" in fn:
        app.logger.warning("action-image reject (bad name): %r", fn)
        abort(404)
    if not re.match(r"^[\w\u4e00-\u9fff\-.]+\.png$", fn):
        app.logger.warning("action-image reject (regex): %r", fn)
        abort(404)
    path = _autism_local_image_path_for_request(fn)
    if not os.path.isfile(path):
        app.logger.warning("action-image 404 (file missing on disk): %s", path)
        abort(404)
    return send_file(path, mimetype="image/png")


@app.route("/autism/action-audio/<fn>", methods=["GET"])
def autism_action_audio_public(fn: str):
    """动态训练图片对应的本地 OGG 标签音频。"""
    raw_fn = fn
    fn = _autism_normalize_action_image_filename(fn)
    if fn != raw_fn:
        app.logger.info("action-audio repaired filename mojibake: %r -> %r", raw_fn, fn)
    if not fn or ".." in fn or "/" in fn or "\\" in fn:
        abort(404)
    if not re.match(r"^[\w\u4e00-\u9fff\-.]+\.ogg$", fn):
        abort(404)
    path = os.path.join(_AUTISM_LOCAL_IMAGE_STORE, fn)
    if not os.path.isfile(path):
        abort(404)
    return send_file(path, mimetype="audio/ogg")


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
        CREATE TABLE IF NOT EXISTS child_profiles (
            child_id INTEGER PRIMARY KEY,
            profile_json TEXT NOT NULL,
            skill_json TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            updated_by_user_id INTEGER,
            FOREIGN KEY (child_id) REFERENCES children(id),
            FOREIGN KEY (updated_by_user_id) REFERENCES users(id)
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
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS autism_child_needs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            child_id INTEGER NOT NULL,
            device_id TEXT,
            card_slug TEXT,
            label TEXT,
            voice_text TEXT,
            created_at TEXT NOT NULL,
            parent_confirmed_at TEXT,
            status TEXT NOT NULL DEFAULT 'pending'
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS autism_training_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            child_id INTEGER NOT NULL,
            scene_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS autism_daily_plans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            child_id INTEGER NOT NULL,
            plan_json TEXT NOT NULL,
            images_json TEXT,
            created_at TEXT NOT NULL,
            applied_at TEXT
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS autism_training_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            child_id INTEGER NOT NULL,
            device_id TEXT,
            scene TEXT NOT NULL,
            phase TEXT NOT NULL,
            payload_json TEXT,
            ts TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """
    )
    cursor.execute("PRAGMA table_info(autism_training_events)")
    _ev_cols = {row[1] for row in cursor.fetchall()}
    if "session_id" not in _ev_cols:
        cursor.execute("ALTER TABLE autism_training_events ADD COLUMN session_id INTEGER")

    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS autism_image_cache (
            cache_key TEXT PRIMARY KEY,
            label_zh TEXT NOT NULL,
            cos_key TEXT NOT NULL,
            public_url TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_autism_image_cache_label_zh
        ON autism_image_cache(label_zh)
        """
    )
    conn.commit()
    conn.close()
    print("✅ 数据库 adhd_data.db 初始化成功")

# 启动时执行初始化
init_db()


def _session_id_from_json(raw):
    """JSON 里的 session_id 可能是 int / str / float；bool 拒绝。"""
    if raw is None or isinstance(raw, bool):
        return None
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def _autism_payload_is_daily_plan_slot(payload, scene: str) -> bool:
    if (scene or "").strip() == "daily_plan":
        return True
    if not isinstance(payload, dict):
        return False
    return payload.get("kind") == "daily_plan" or payload.get("source") == "daily_plan"


def _autism_payload_is_app_child_training(payload, scene: str) -> bool:
    """App 下发的场景跟选训练（单次预设），不含时间表 daily_plan。"""
    if _autism_payload_is_daily_plan_slot(payload, scene):
        return False
    if not isinstance(payload, dict):
        return False
    return (payload.get("source") or "") == "child_training" or (payload.get("kind") or "") == "training_start"


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


def _compact_text(value, limit=120):
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    return text[:limit]


def _child_profile_default(child_id, nickname):
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    profile = {
        "childId": child_id,
        "nickname": nickname or "孩子",
        "updatedAt": now,
    }
    return profile, _build_child_skill(profile, now)


def _profile_display_name(profile):
    for key in ("nickname", "name"):
        value = _compact_text(profile.get(key), 40)
        if value:
            return value
    return "孩子"


def _build_child_skill(profile, updated_at=None):
    display_name = _profile_display_name(profile)
    age = profile.get("age")
    gender = _compact_text(profile.get("gender"), 20)
    personality = _compact_text(profile.get("personality"), 80)
    interests = _compact_text(profile.get("interests"), 80)
    category = _compact_text(profile.get("category"), 60)
    note = _compact_text(profile.get("note"), 100)
    traits = []
    if age not in (None, ""):
        traits.append(f"{age} 岁")
    if gender:
        traits.append(gender)
    if category:
        traits.append(category)
    if personality:
        traits.append(f"性格：{personality}")
    if interests:
        traits.append(f"喜欢：{interests}")
    intro_parts = [f"你好呀，我是 {display_name}。"]
    if traits:
        intro_parts.append("我有这些小特点：" + "，".join(traits) + "。")
    if note:
        intro_parts.append(f"家人还希望你记住：{note}。")
    intro_parts.append("你可以温柔地问问我今天的感受，也可以帮爸爸妈妈更懂我。")
    support_hints = []
    if personality:
        support_hints.append(f"沟通时先照顾我的性格特点：{personality}。")
    if interests:
        support_hints.append(f"可以用我喜欢的 {interests} 作为进入对话或转移注意力的入口。")
    if category:
        support_hints.append(f"支持我时请结合 {category} 相关的节奏、感官和注意力需求。")
    if note:
        support_hints.append(f"额外注意：{note}。")
    if not support_hints:
        support_hints.append("先用短句、慢节奏和明确选择帮助我表达感受。")
    conversation_style_parts = ["像一个被家人认真理解的卡通小孩，回答简短、真诚、温暖。"]
    if personality:
        conversation_style_parts.append(f"回答要体现「{personality}」这类性格特点。")
    if interests:
        conversation_style_parts.append(f"可以自然提到「{interests}」，但不要每句都重复。")
    quick_questions = [
        "我可以怎样帮助你？",
        "你最近感觉如何？",
        "你可以介绍下自己吗？",
    ]
    if interests:
        quick_questions.append(f"我喜欢的 {interests} 可以怎么帮我放松？")
    palette_seed = sum(ord(ch) for ch in display_name) % 3
    avatar_styles = [
        {"theme": "sunny", "primaryColor": "#F2B35D", "accentColor": "#6FAF8E"},
        {"theme": "calm", "primaryColor": "#74A6D6", "accentColor": "#E7A6B8"},
        {"theme": "forest", "primaryColor": "#78B783", "accentColor": "#E6C16A"},
    ]
    return {
        "version": 1,
        "displayName": display_name,
        "summary": " ".join(intro_parts),
        "selfIntroduction": " ".join(intro_parts),
        "conversationStyle": " ".join(conversation_style_parts),
        "supportHints": support_hints,
        "avatar": avatar_styles[palette_seed],
        "quickQuestions": quick_questions[:4],
        "optimizedFromProfileAt": updated_at or datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "updatedAt": updated_at or datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }


def _read_child_profile_row(cursor, child_id):
    cursor.execute(
        """
        SELECT c.nickname, p.profile_json, p.skill_json, p.updated_at, p.updated_by_user_id
        FROM children c
        LEFT JOIN child_profiles p ON p.child_id = c.id
        WHERE c.id = ?
        """,
        (child_id,),
    )
    row = cursor.fetchone()
    if not row:
        return None
    nickname, profile_raw, skill_raw, updated_at, updated_by = row
    if profile_raw:
        try:
            profile = json.loads(profile_raw)
        except Exception:
            profile = {}
    else:
        profile = {}
    if skill_raw:
        try:
            skill = json.loads(skill_raw)
        except Exception:
            skill = {}
    else:
        skill = {}
    if not profile:
        profile, skill = _child_profile_default(child_id, nickname)
    if not skill:
        skill = _build_child_skill(profile, updated_at)
    profile["childId"] = child_id
    return {
        "child_id": child_id,
        "nickname": nickname,
        "profile": profile,
        "skill": skill,
        "updated_at": updated_at or profile.get("updatedAt") or skill.get("updatedAt"),
        "updated_by_user_id": updated_by,
    }


def _child_profile_category_is_autism(cursor, child_id: int) -> bool:
    """与 App `ChildCondition` / profile.category 一致：孤独症孩子走训练向报告，不含心率。"""
    row = _read_child_profile_row(cursor, child_id)
    if not row:
        return False
    profile = row.get("profile") or {}
    cat = str(profile.get("category") or profile.get("categoryLabel") or "").strip()
    if not cat:
        return False
    low = cat.lower()
    if "孤独" in cat or "自闭" in cat or "谱系" in cat:
        return True
    if "asd" in low or "autism" in low:
        return True
    return False


def _skill_list_append_unique(items, value, limit=12):
    if not isinstance(items, list):
        items = []
    text = _compact_text(value, 60)
    if not text:
        return items[-limit:]
    existing = []
    for item in items:
        if isinstance(item, dict):
            existing.append(_compact_text(item.get("label") or item.get("text"), 60))
        else:
            existing.append(_compact_text(item, 60))
    if text not in existing:
        items.append(text)
    return items[-limit:]


def _skill_fact_append_unique(items, fact, limit=30):
    if not isinstance(items, list):
        items = []
    label = _compact_text((fact or {}).get("label"), 60)
    kind = _compact_text((fact or {}).get("kind"), 40)
    source = _compact_text((fact or {}).get("source"), 40)
    if not label:
        return items[-limit:]
    for item in items:
        if not isinstance(item, dict):
            continue
        if (
            _compact_text(item.get("label"), 60) == label
            and _compact_text(item.get("kind"), 40) == kind
            and _compact_text(item.get("source"), 40) == source
        ):
            item["count"] = int(item.get("count") or 1) + 1
            item["lastSeenAt"] = fact.get("lastSeenAt")
            return items[-limit:]
    items.append(fact)
    return items[-limit:]


def _refresh_skill_text_from_learned_facts(skill):
    base = skill.get("baseSummary")
    if not base:
        base = skill.get("summary") or skill.get("selfIntroduction") or ""
        skill["baseSummary"] = base
    base_intro = skill.get("baseSelfIntroduction")
    if not base_intro:
        base_intro = skill.get("selfIntroduction") or base
        skill["baseSelfIntroduction"] = base_intro

    needs = skill.get("childInitiatedNeeds") if isinstance(skill.get("childInitiatedNeeds"), list) else []
    prefs = skill.get("observedPreferences") if isinstance(skill.get("observedPreferences"), list) else []
    daily = skill.get("dailyPlanPreferences") if isinstance(skill.get("dailyPlanPreferences"), list) else []
    training = skill.get("trainingInsights") if isinstance(skill.get("trainingInsights"), list) else []

    learned_parts = []
    if needs:
        learned_parts.append("孩子曾主动表达：" + "、".join(str(x) for x in needs[-5:]) + "。")
    if prefs:
        learned_parts.append("近期观察到的偏好/选择：" + "、".join(str(x) for x in prefs[-8:]) + "。")
    if daily:
        learned_parts.append("日常计划中常见选择：" + "、".join(str(x) for x in daily[-6:]) + "。")
    if training:
        learned_parts.append("训练中出现过的选择：" + "、".join(str(x) for x in training[-6:]) + "。")

    learned = " ".join(learned_parts)
    skill["learnedSummary"] = learned
    skill["summary"] = (base + (" " + learned if learned else "")).strip()
    skill["selfIntroduction"] = (base_intro + (" " + learned if learned else "")).strip()

    support_hints = skill.get("supportHints") if isinstance(skill.get("supportHints"), list) else []
    if prefs:
        hint = "沟通或设计选择时，可优先参考已观察到的偏好：" + "、".join(str(x) for x in prefs[-5:]) + "。"
        support_hints = _skill_list_append_unique(support_hints, hint, limit=10)
    if needs:
        hint = "孩子已经能通过星星主动表达部分需求，家长可及时回应并复述需求词。"
        support_hints = _skill_list_append_unique(support_hints, hint, limit=10)
    skill["supportHints"] = support_hints

    qq = skill.get("quickQuestions") if isinstance(skill.get("quickQuestions"), list) else []
    qq = _skill_list_append_unique(qq, "最近孩子更常选择什么？", limit=4)
    skill["quickQuestions"] = qq[:4]


def _enrich_child_skill_from_autism_event(cursor, child_id, *, kind, label, source="", scene="", ts=None, payload=None):
    label = _compact_text(label, 60)
    if not label:
        return
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    ts = ts or now
    row = _read_child_profile_row(cursor, child_id)
    if row:
        profile = row["profile"]
        skill = row["skill"] or _build_child_skill(row["profile"], now)
        updated_by = row.get("updated_by_user_id")
    else:
        profile, skill = _child_profile_default(child_id, "孩子")
        updated_by = None

    kind = _compact_text(kind, 40) or "autism_event"
    source = _compact_text(source, 40)
    scene = _compact_text(scene, 60)
    fact = {
        "kind": kind,
        "label": label,
        "source": source,
        "scene": scene,
        "lastSeenAt": ts,
        "count": 1,
    }
    if isinstance(payload, dict):
        slot_time = _compact_text(payload.get("slot_time"), 20)
        if slot_time:
            fact["slotTime"] = slot_time

    skill["eventFacts"] = _skill_fact_append_unique(skill.get("eventFacts"), fact, limit=40)

    if kind == "child_initiated_need":
        skill["childInitiatedNeeds"] = _skill_list_append_unique(
            skill.get("childInitiatedNeeds"), label, limit=12
        )
    elif source == "daily_plan" or scene == "daily_plan":
        skill["dailyPlanPreferences"] = _skill_list_append_unique(
            skill.get("dailyPlanPreferences"), label, limit=12
        )
        skill["observedPreferences"] = _skill_list_append_unique(
            skill.get("observedPreferences"), label, limit=16
        )
    else:
        skill["trainingInsights"] = _skill_list_append_unique(
            skill.get("trainingInsights"), label, limit=12
        )
        skill["observedPreferences"] = _skill_list_append_unique(
            skill.get("observedPreferences"), label, limit=16
        )

    skill["lastAutismEventAt"] = ts
    skill["updatedAt"] = now
    _refresh_skill_text_from_learned_facts(skill)

    profile["childId"] = child_id
    profile.setdefault("updatedAt", now)
    cursor.execute(
        """
        INSERT INTO child_profiles
        (child_id, profile_json, skill_json, updated_at, updated_by_user_id)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(child_id) DO UPDATE SET
            profile_json = excluded.profile_json,
            skill_json = excluded.skill_json,
            updated_at = excluded.updated_at,
            updated_by_user_id = child_profiles.updated_by_user_id
        """,
        (
            child_id,
            json.dumps(profile, ensure_ascii=False),
            json.dumps(skill, ensure_ascii=False),
            now,
            updated_by,
        ),
    )


def _recent_child_skill_context(cursor, child_id):
    cursor.execute(
        """
        SELECT observation, ai_advice, bpm, condition_type, timestamp
        FROM parent_logs
        WHERE child_id = ?
        ORDER BY timestamp DESC, id DESC
        LIMIT 1
        """,
        (child_id,),
    )
    log = cursor.fetchone()
    cursor.execute(
        """
        SELECT bpm, timestamp
        FROM heart_rate_history
        WHERE child_id = ? AND bpm > 0
        ORDER BY timestamp DESC, id DESC
        LIMIT 1
        """,
        (child_id,),
    )
    hr = cursor.fetchone()
    context = {}
    if log:
        context["latestObservation"] = {
            "observation": log[0],
            "advice": log[1],
            "bpm": log[2],
            "conditionType": log[3],
            "timestamp": log[4],
        }
    if hr:
        context["latestHeartRate"] = {"bpm": hr[0], "timestamp": hr[1]}
    return context


def _fixed_child_skill_answer(question, profile, skill, context):
    q = re.sub(r"\s+", "", str(question or "")).lower()
    display_name = skill.get("displayName") or _profile_display_name(profile)
    interests = _compact_text(profile.get("interests"), 80)
    personality = _compact_text(profile.get("personality"), 80)
    support_hints = skill.get("supportHints") if isinstance(skill.get("supportHints"), list) else []
    observed_preferences = skill.get("observedPreferences") if isinstance(skill.get("observedPreferences"), list) else []
    child_needs = skill.get("childInitiatedNeeds") if isinstance(skill.get("childInitiatedNeeds"), list) else []
    latest_hr = (context.get("latestHeartRate") or {}).get("bpm")
    latest_obs = _compact_text((context.get("latestObservation") or {}).get("observation"), 80)
    if any(key in q for key in ("喜欢", "偏好", "选择", "爱吃", "爱玩")) and observed_preferences:
        return f"最近我常选择：{'、'.join(str(x) for x in observed_preferences[-8:])}。这些可以先当作线索，继续观察我是不是稳定喜欢。"
    if any(key in q for key in ("需要", "需求", "主动", "想要")) and child_needs:
        return f"我已经通过星星主动表达过：{'、'.join(str(x) for x in child_needs[-6:])}。家长可以及时回应，并帮我复述出来。"
    if any(key in q for key in ("介绍", "自己", "你是谁", "自我")):
        return skill.get("selfIntroduction") or _build_child_skill(profile).get("selfIntroduction")
    if any(key in q for key in ("感觉", "最近", "今天", "心情")):
        parts = [f"我是 {display_name}，我希望大人先慢慢听我说。"]
        if latest_hr:
            parts.append(f"最近一次心率大约是 {latest_hr:.0f}，可以结合当时环境一起看看我是不是有点紧绷。")
        if latest_obs:
            parts.append(f"家人最近记录到：{latest_obs}。")
        if not latest_hr and not latest_obs:
            parts.append("现在还没有太多近期记录，你可以从表情、动作和我愿不愿意继续玩来观察我。")
        return "".join(parts)
    if any(key in q for key in ("帮助", "帮你", "需要什么", "怎样帮")):
        tips = [f"你可以先叫我的小名 {display_name}，蹲下来用短句问我。"]
        if personality:
            tips.append(f"记得我的性格特点是：{personality}。")
        if interests:
            tips.append(f"也可以从我喜欢的 {interests} 开始，让我更容易放松。")
        for hint in support_hints[:2]:
            hint_text = _compact_text(hint, 80)
            if hint_text:
                tips.append(hint_text)
        tips.append("如果我心率或压力偏高，先减少刺激、给我一点选择，再继续沟通。")
        return "".join(tips)
    return None


def fetch_kimi_child_skill_answer(question, profile, skill, context):
    display_name = skill.get("displayName") or _profile_display_name(profile)
    profile_brief = json.dumps(
        {
            "name": profile.get("name"),
            "nickname": profile.get("nickname"),
            "age": profile.get("age"),
            "gender": profile.get("gender"),
            "category": profile.get("category"),
            "personality": profile.get("personality"),
            "interests": profile.get("interests"),
            "note": profile.get("note"),
        },
        ensure_ascii=False,
    )
    context_brief = json.dumps(context or {}, ensure_ascii=False)
    skill_brief = json.dumps(
        {
            "conversationStyle": skill.get("conversationStyle"),
            "supportHints": skill.get("supportHints"),
            "observedPreferences": skill.get("observedPreferences"),
            "childInitiatedNeeds": skill.get("childInitiatedNeeds"),
            "trainingInsights": skill.get("trainingInsights"),
            "dailyPlanPreferences": skill.get("dailyPlanPreferences"),
            "learnedSummary": skill.get("learnedSummary"),
            "eventFacts": skill.get("eventFacts"),
            "optimizedFromProfileAt": skill.get("optimizedFromProfileAt"),
        },
        ensure_ascii=False,
    )
    system = (
        "你是家长版 App 里的孩子画像 skill，不是小智机器人。"
        "请基于家长录入的孩子资料，用卡通小孩第一人称回答家长问题。"
        "回答要温暖、简短、具体，避免诊断结论，不编造未提供的事实。"
    )
    prompt = (
        f"孩子称呼：{display_name}\n"
        f"孩子资料 JSON：{profile_brief}\n"
        f"当前已优化 skill JSON：{skill_brief}\n"
        f"近期行为和心率上下文 JSON：{context_brief}\n"
        f"家长问题：{_compact_text(question, 300)}\n"
        "请用 80 字以内中文回答。"
    )
    try:
        response = _kimi_chat_create(
            model=_moonshot_chat_model(),
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
            temperature=0.6,
        )
        return response.choices[0].message.content
    except Exception as e:
        print(f"Kimi child skill 错误: {e}")
        return _fixed_child_skill_answer("我可以怎样帮助你？", profile, skill, context)


def fetch_kimi_teacher_threshold_suggestion(profile, current_rule):
    """为教师版学生生成个性化心率提醒阈值建议。

    这是课堂提醒阈值，不是诊断结论；AI 只能在年龄规则基础上做温和调整。
    """
    age = profile.get("age")
    low = int(current_rule.get("low") or 70)
    high = int(current_rule.get("high") or 120)
    fallback = {
        "lowThresholdBpm": low,
        "highThresholdBpm": high,
        "reason": "AI 暂不可用，已沿用当前年龄规则阈值。建议结合课堂表现和持续心率记录再微调。",
        "source": "fallback",
    }
    profile_brief = json.dumps(
        {
            "name": profile.get("name"),
            "nickname": profile.get("nickname"),
            "age": age,
            "gender": profile.get("gender"),
            "category": profile.get("category"),
            "personality": profile.get("personality"),
            "interests": profile.get("interests"),
            "note": profile.get("note"),
        },
        ensure_ascii=False,
    )
    rule_brief = json.dumps(current_rule or {}, ensure_ascii=False)
    system = (
        "你是儿童课堂心率监测阈值建议助手。"
        "你只能基于年龄规则、性别、年龄、性格、兴趣、支持类别和备注，给老师一个课堂提醒阈值建议。"
        "不要给医学诊断，不要声称可以替代医生。阈值应保守、可解释，避免过度告警。"
        "必须只输出 JSON 对象。"
    )
    prompt = (
        f"当前年龄规则阈值 JSON：{rule_brief}\n"
        f"学生资料 JSON：{profile_brief}\n"
        "请输出 JSON："
        "{\"lowThresholdBpm\":整数,\"highThresholdBpm\":整数,\"reason\":\"80字以内中文理由\"}。"
        "约束：lowThresholdBpm 必须小于 highThresholdBpm；low 在 45-120；high 在 90-180；"
        "如果资料不足，尽量接近年龄规则。"
    )
    try:
        response = _kimi_chat_create(
            model=_moonshot_chat_model(),
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
            temperature=0.2,
        )
        parsed = _extract_json_object(response.choices[0].message.content)
        if not parsed:
            return fallback
        next_low = int(parsed.get("lowThresholdBpm", low))
        next_high = int(parsed.get("highThresholdBpm", high))
        next_low = max(45, min(120, next_low))
        next_high = max(90, min(180, next_high))
        if next_low >= next_high:
            next_low, next_high = low, high
        return {
            "lowThresholdBpm": next_low,
            "highThresholdBpm": next_high,
            "reason": _compact_text(parsed.get("reason"), 160)
            or "已基于当前年龄规则和学生资料生成课堂提醒阈值。",
            "source": "kimi",
        }
    except Exception as e:
        print(f"Kimi teacher threshold 错误: {e}")
        return fallback


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
    behavior_scene = re.sub(r"\s+", " ", str(observation or "")).strip()
    behavior_scene = behavior_scene[:120]
    system = (
        "你是帮助特殊儿童家长写小红书树洞帖的中文编辑。"
        "目标是保护隐私、降低诊断化表达、保留真实处境和共鸣感，方便类似情况的家长交流。"
        "不得编造学校、城市、姓名、医院、班级、具体年龄、精确时间地点等隐私信息。"
        "你写出来的内容要像家长在深夜认真整理自己的心情，不像健康科普、AI 总结或产品文案。"
    )
    prompt = (
        "请把下面这条家长现场记录改写成一篇可编辑的小红书草稿。\n"
        f"孩子主要支持方向：{label}\n"
        f"状态背景：{bpm_desc}\n"
        f"家长原始观察：{behavior_scene}\n"
        f"当时给家长的建议摘要：{advice or '无'}\n\n"
        "要求：\n"
        "0. 【核心要求，优先级最高】文章必须以家长原始观察描述的那个具体行为情景为主线展开，"
        "   不能替换成别的情景、不能架空泛化为「孩子状态有些紧绷」之类的模糊描述；"
        "   行为动作、情绪反应、当时场景（如写作业、大叫、来回踱步等）必须保留在正文中。\n"
        "1. 标题必须点出这次记录里的具体行为或场景，不要写成泛泛的「今天又被拉扯」。\n"
        "2. 正文第一段就要写出这次行为：可以自然改写，但读者必须一眼看出和原始观察有关。\n"
        "3. 用第一人称写，允许出现家长的犹豫、自责、心疼、努力稳住自己的过程；"
        "   不要使用「首先/其次/建议/干预」这类机械分点表达。\n"
        "4. 只隐去可识别个人身份的隐私：不出现姓名、学校名、住址、医院名、设备型号、"
        "   精确心率数值、具体日期时间。孩子的行为本身不属于隐私，不能删除或泛化。\n"
        "5. 可以增加少量生活化描写（地点改为「家里/外出」等泛化说法），但不能编造新的敏感事实。\n"
        "6. 结尾邀请有类似经历的家长交流，可以把建议摘要改写成一句温柔的自我提醒。\n"
        "7. 返回严格 JSON：{\"title\":\"...\",\"content\":\"...\",\"tags\":[\"...\",\"...\"]}。"
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
                if behavior_scene and behavior_scene[:12] not in content:
                    content = f"刚才记录下来的那一幕是：{behavior_scene}。\n\n{content}"
                return {
                    "title": title[:80],
                    "content": content[:1200],
                    "tags": tags[:8],
                }
    except Exception as e:
        print(f"Kimi 小红书草稿生成错误: {e}")

    scene = behavior_scene or "孩子刚才的反应让我有点措手不及"
    fallback_title = f"记录一下刚才那一幕：{scene[:24]}"
    fallback_content = (
        f"今天想来这里树洞一下。刚才我记录到的是：{scene}。"
        "看到孩子卡在那个状态里，我第一反应其实也会慌，会担心自己是不是又没接住。"
        "后来我提醒自己先别急着讲道理，声音放轻一点，把眼前的事拆小一点，先陪孩子把这一阵缓过去。"
        "养育这样的孩子，很多时候不是不爱，也不是不努力，而是大人和孩子都在学着慢一点。"
        "有没有类似经历的家长？你们遇到这种具体场景时，会怎么陪孩子走出来？"
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
        is_autism = _child_profile_category_is_autism(cursor, cid)

        if is_autism:
            cursor.execute(
                """
                SELECT id, timestamp, bpm, observation, ai_advice, condition_type
                FROM parent_logs
                WHERE child_id = ? AND timestamp LIKE ?
                  AND LOWER(COALESCE(condition_type, '')) = 'autism'
                ORDER BY id ASC
                """,
                (cid, prefix),
            )
        else:
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
            if is_autism:
                trend_code, trend_label, avg_b, avg_a, nb, na = (
                    "unknown",
                    "（孤独症向记录不对比心率）",
                    None,
                    None,
                    0,
                    0,
                )
            else:
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

        cursor.execute(
            """
            SELECT id, device_id, scene, phase, payload_json, ts, created_at
            FROM autism_training_events
            WHERE child_id = ? AND ts LIKE ?
            ORDER BY id ASC
            """,
            (cid, prefix),
        )
        autism_events = []
        for eid, device_id, scene, phase, payload_json, ts, created_at in cursor.fetchall():
            try:
                payload = json.loads(payload_json or "{}")
            except Exception:
                payload = {}
            autism_events.append(
                {
                    "id": eid,
                    "device_id": device_id,
                    "scene": scene,
                    "phase": phase,
                    "payload": payload,
                    "ts": ts,
                    "created_at": created_at,
                }
            )

        cursor.execute(
            """
            SELECT id, device_id, card_slug, label, voice_text, created_at, status, parent_confirmed_at
            FROM autism_child_needs
            WHERE child_id = ? AND created_at LIKE ?
            ORDER BY id ASC
            """,
            (cid, prefix),
        )
        child_initiated_needs = []
        for nid, device_id, card_slug, label, voice_text, created_at, status, parent_confirmed_at in cursor.fetchall():
            child_initiated_needs.append(
                {
                    "id": nid,
                    "device_id": device_id,
                    "card_slug": card_slug,
                    "label": label,
                    "voice_text": voice_text,
                    "created_at": created_at,
                    "status": status,
                    "parent_confirmed_at": parent_confirmed_at,
                }
            )

        conn.close()
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

    return jsonify(
        {
            "child_id": cid,
            "date": date_str,
            "report_focus": "autism" if is_autism else "adhd",
            "log_count": len(logs_out),
            "training_event_count": len(autism_events),
            "child_need_count": len(child_initiated_needs),
            "trend_summary": summary,
            "logs": logs_out,
            "autism_training_events": autism_events,
            "child_initiated_needs": child_initiated_needs,
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


def _collect_week_digest(cursor, t_lo: str, t_hi: str, child_id: int, *, for_autism: bool = False):
    """聚合周期内数据供 Kimi 与 digest_json 存档。孤独症模式不含心率，以训练事件与家长笔记为主。"""
    if not for_autism:
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
    else:
        heart_n = 0
        heart_avg = heart_min = heart_max = None
        alert_sum = 0
        hourly_stress = []
        daily = []

    log_limit = 60 if for_autism else 40
    if for_autism:
        cursor.execute(
            """
            SELECT timestamp, bpm, observation, ai_advice,
                   COALESCE(condition_type, 'autism') AS ctype
            FROM parent_logs
            WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
                  AND LOWER(COALESCE(condition_type, '')) = 'autism'
            ORDER BY timestamp DESC
            LIMIT ?
            """,
            (child_id, t_lo, t_hi, log_limit),
        )
    else:
        cursor.execute(
            """
            SELECT timestamp, bpm, observation, ai_advice,
                   COALESCE(condition_type, 'adhd') AS ctype
            FROM parent_logs
            WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp DESC
            LIMIT ?
            """,
            (child_id, t_lo, t_hi, log_limit),
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
                "condition_label": _condition_label(str(ctype).lower()),
            }
        )

    autism_limit = 400 if for_autism else 80
    cursor.execute(
        """
        SELECT ts, scene, phase, payload_json
        FROM autism_training_events
        WHERE child_id = ? AND ts >= ? AND ts <= ?
        ORDER BY ts ASC
        LIMIT ?
        """,
        (child_id, t_lo, t_hi, autism_limit),
    )
    autism_events = []
    for ts, scene, phase, payload_json in cursor.fetchall():
        try:
            payload = json.loads(payload_json or "{}")
        except Exception:
            payload = {}
        autism_events.append(
            {
                "timestamp": ts,
                "scene": scene,
                "phase": phase,
                "label": payload.get("label"),
                "source": payload.get("source"),
                "slot_time": payload.get("slot_time"),
            }
        )

    needs_limit = 120 if for_autism else 80
    cursor.execute(
        """
        SELECT created_at, card_slug, label, voice_text, status, parent_confirmed_at
        FROM autism_child_needs
        WHERE child_id = ? AND created_at >= ? AND created_at <= ?
        ORDER BY created_at ASC
        LIMIT ?
        """,
        (child_id, t_lo, t_hi, needs_limit),
    )
    child_initiated_needs = []
    for created_at, card_slug, label, voice_text, status, parent_confirmed_at in cursor.fetchall():
        child_initiated_needs.append(
            {
                "timestamp": created_at,
                "card_slug": card_slug,
                "label": label,
                "voice_text": voice_text,
                "status": status,
                "parent_confirmed_at": parent_confirmed_at,
            }
        )

    return {
        "report_focus": "autism" if for_autism else "adhd",
        "heart_sample_count": heart_n,
        "heart_avg_bpm": round(heart_avg, 1) if heart_avg is not None else None,
        "heart_min_bpm": round(heart_min, 1) if heart_min is not None else None,
        "heart_max_bpm": round(heart_max, 1) if heart_max is not None else None,
        "heart_alert_count": alert_sum,
        "hourly_stress_ranked": hourly_stress,
        "daily_heart": daily,
        "parent_logs": logs,
        "autism_training_events": autism_events,
        "child_initiated_needs": child_initiated_needs,
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

    needs = digest.get("child_initiated_needs") or []
    lines += ["", f"【孩子主动发起需求】共 {len(needs)} 条"]
    for n in needs:
        lines.append(
            f"- {n['timestamp']} 孩子选择：{n.get('label') or '未记录'} 状态：{n.get('status') or 'unknown'}"
        )
    if not needs:
        lines.append("- （该周暂无孩子主动发起需求记录）")

    events = digest.get("autism_training_events") or []
    lines += ["", f"【孤独症训练 / 日常计划事件】共 {len(events)} 条"]
    for e in events:
        label = e.get("label") or "未记录选项"
        slot = f" 时间={e.get('slot_time')}" if e.get("slot_time") else ""
        lines.append(
            f"- {e['timestamp']} scene={e['scene']} phase={e['phase']}{slot} 选择：{label}"
        )
    if not events:
        lines.append("- （该周暂无训练或日常计划选择事件）")

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
    *,
    for_autism: bool = False,
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

    if for_autism:
        lines = [
            f"请根据以下「{range_label}摘要」（孤独症支持向，不含手环心率），给家长写一份中文「AI {report_label}」。",
            "",
            f"【统计周期】{period_start} 至 {period_end}",
            f"【孩子称呼】{child_name}（文中可直接用此称呼）",
            "",
            "【数据说明】本档案为孤独症谱系支持向：摘要中仅含「星星机器人训练/日常计划事件」、"
            "「家长笔记（孤独症类）」与「孩子主动发起需求」。请勿推断或描述心率、BPM、手环采样等（本周期无此类数据）。",
        ]
        logs = digest.get("parent_logs") or []
        lines += ["", f"【家长笔记（孤独症类）】共 {len(logs)} 条"]
        for p in logs:
            lines.append(f"- {p['timestamp']} 观察：{p['observation']}")
            adv = (p.get("ai_advice_snippet") or "").strip()
            if adv:
                lines.append(f"  当时建议摘要：{adv}")
        if not logs:
            lines.append("- （该周期暂无此类家长笔记）")

        needs = digest.get("child_initiated_needs") or []
        lines += ["", f"【孩子主动发起需求】共 {len(needs)} 条"]
        for n in needs:
            lines.append(
                f"- {n['timestamp']} 孩子选择：{n.get('label') or '未记录'} 状态：{n.get('status') or 'unknown'}"
            )
        if not needs:
            lines.append("- （该周期暂无孩子主动发起需求记录）")

        events = digest.get("autism_training_events") or []
        lines += ["", f"【孤独症训练 / 日常计划事件】共 {len(events)} 条"]
        for e in events:
            label = e.get("label") or "（无选项文字）"
            slot = f" 时间={e.get('slot_time')}" if e.get("slot_time") else ""
            lines.append(
                f"- {e['timestamp']} scene={e['scene']} phase={e['phase']}{slot} 选择/结果：{label}"
            )
        if not events:
            lines.append("- （该周期暂无训练或日常计划事件）")

        lines += [
            "",
            "【写作要求】",
            "1. 用自然、亲切的第二人称写给家长；不要医学诊断，不要替代就医。",
            "2. 围绕训练互动、日常计划执行、孩子主动表达与家长笔记，归纳规律、亮点与可改进处；不要编造心率或生理数据。",
            f"3. {suggestion_hint}",
            "4. 对自闭症谱系支持保持温和、具体、非标签化表达。",
            f"5. {length_hint}，不要用 Markdown 标题符号，不要输出 JSON。",
        ]
        return "\n".join(lines)

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

    needs = digest.get("child_initiated_needs") or []
    lines += ["", f"【孩子主动发起需求】共 {len(needs)} 条"]
    for n in needs:
        lines.append(
            f"- {n['timestamp']} 孩子选择：{n.get('label') or '未记录'} 状态：{n.get('status') or 'unknown'}"
        )
    if not needs:
        lines.append("- （该周期暂无孩子主动发起需求记录）")

    events = digest.get("autism_training_events") or []
    lines += ["", f"【孤独症训练 / 日常计划事件】共 {len(events)} 条"]
    for e in events:
        label = e.get("label") or "未记录选项"
        slot = f" 时间={e.get('slot_time')}" if e.get("slot_time") else ""
        lines.append(
            f"- {e['timestamp']} scene={e['scene']} phase={e['phase']}{slot} 选择：{label}"
        )
    if not events:
        lines.append("- （该周期暂无训练或日常计划选择事件）")

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
            temperature=0.6,
            max_tokens=2800,
        )
        text = (response.choices[0].message.content or "").strip()
        return text
    except Exception as e:
        print(f"Kimi 周报 API 错误: {e}")
        raise


def fetch_kimi_period_report(
    period_type: str, user_prompt: str, *, for_autism: bool = False
) -> str:
    """调用 Kimi 生成周/月/年周期报告。"""
    report_label = _PERIOD_LABELS.get(period_type, "报告")
    if for_autism:
        system = (
            "你是儿童发育与特殊教育领域的资深顾问，擅长自闭症谱系的沟通、情绪与结构化支持。"
            f"你仅根据「孤独症训练/日常计划事件」与家长文字笔记撰写「{report_label}」，"
            "不要描述或推断心率、手环采样、BPM 等（本场景不存在此类数据）。"
            "语气专业、温暖、具体。严禁医学诊断与面诊替代。数据不足时要明确说明，不编造趋势。"
        )
    else:
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
            temperature=0.6,
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
    for_autism = _child_profile_category_is_autism(cursor, child_id)
    digest = _collect_week_digest(cursor, t_lo, t_hi, child_id, for_autism=for_autism)
    row_name = _read_child_profile_row(cursor, child_id)
    conn.close()

    child_name = "孩子"
    if row_name:
        nick = (row_name.get("nickname") or "").strip()
        if nick:
            child_name = nick
    if not child_name or child_name == "孩子":
        child_name = (os.getenv("CHILD_DISPLAY_NAME") or "孩子").strip() or "孩子"
    user_prompt = _build_period_kimi_user_prompt(
        period_type,
        child_name,
        period_start,
        period_end,
        digest,
        for_autism=for_autism,
    )
    summary = fetch_kimi_period_report(period_type, user_prompt, for_autism=for_autism)
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
    is_autism = _child_profile_category_is_autism(cursor, cid)

    if is_autism:
        cursor.execute(
            """
            SELECT COUNT(*) FROM (
                SELECT substr(ts, 1, 10) AS d FROM autism_training_events
                WHERE child_id = ? AND ts >= ? AND ts <= ?
                UNION
                SELECT substr(created_at, 1, 10) AS d FROM autism_child_needs
                WHERE child_id = ? AND created_at >= ? AND created_at <= ?
                UNION
                SELECT substr(timestamp, 1, 10) AS d FROM parent_logs
                WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
                  AND LOWER(COALESCE(condition_type, '')) = 'autism'
            ) AS active_days
            """,
            (cid, t_lo, t_hi, cid, t_lo, t_hi, cid, t_lo, t_hi),
        )
        days_collected = int(cursor.fetchone()[0] or 0)
        cursor.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM autism_training_events
               WHERE child_id = ? AND ts >= ? AND ts <= ?)
            + (SELECT COUNT(*) FROM autism_child_needs
               WHERE child_id = ? AND created_at >= ? AND created_at <= ?)
            + (SELECT COUNT(*) FROM parent_logs
               WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
                 AND LOWER(COALESCE(condition_type, '')) = 'autism')
            """,
            (cid, t_lo, t_hi, cid, t_lo, t_hi, cid, t_lo, t_hi),
        )
        log_count = int(cursor.fetchone()[0] or 0)
    else:
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
        if is_autism:
            cursor.execute(
                """
                SELECT
                  (SELECT COUNT(*) FROM autism_training_events
                   WHERE child_id = ? AND ts >= ? AND ts <= ?)
                + (SELECT COUNT(*) FROM autism_child_needs
                   WHERE child_id = ? AND created_at >= ? AND created_at <= ?)
                + (SELECT COUNT(*) FROM parent_logs
                   WHERE child_id = ? AND timestamp >= ? AND timestamp <= ?
                     AND LOWER(COALESCE(condition_type, '')) = 'autism')
                """,
                (cid, lt_lo, lt_hi, cid, lt_lo, lt_hi, cid, lt_lo, lt_hi),
            )
            has_touch = (cursor.fetchone()[0] or 0) > 0
            last_status = "ready" if has_touch else "no_data"
        else:
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
        "report_focus": "autism" if is_autism else "adhd",
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


@app.route("/my/config/xiaomi-band-auth-key", methods=["GET"])
def my_config_xiaomi_band_auth_key():
    """已登录用户拉取服务器配置的小米手环 BLE 鉴权密钥（32 hex）。来源：环境变量 XIAOMI_AUTH_KEY（见 ~/.config/adhd-monitor.env）。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    raw = (os.getenv("XIAOMI_AUTH_KEY") or "").strip()
    if not raw:
        return (
            jsonify(
                {
                    "status": "error",
                    "message": "server XIAOMI_AUTH_KEY not configured",
                }
            ),
            503,
        )
    nk = re.sub(r"\s+", "", raw).lower()
    if not re.fullmatch(r"[0-9a-f]{32}", nk):
        print(
            "⚠️ XIAOMI_AUTH_KEY 应为 32 位十六进制（去空格后校验失败），已拒绝下发",
            file=sys.stderr,
        )
        return jsonify({"status": "error", "message": "invalid XIAOMI_AUTH_KEY on server"}), 500
    return jsonify({"status": "ok", "auth_hex_key": nk}), 200


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


@app.route("/my/children/<int:child_id>/profile", methods=["GET"])
def my_child_profile_get(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    row = _read_child_profile_row(cursor, child_id)
    conn.close()
    if not row:
        return jsonify({"status": "error", "message": "child not found"}), 404
    return jsonify({"status": "ok", **row}), 200


@app.route("/my/children/<int:child_id>/profile", methods=["PUT"])
def my_child_profile_put(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    raw_profile = data.get("profile") if isinstance(data.get("profile"), dict) else data
    profile = dict(raw_profile or {})
    profile["childId"] = child_id
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    profile["updatedAt"] = now
    skill = _build_child_skill(profile, now)
    nickname = _compact_text(profile.get("nickname") or profile.get("name"), 40)
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    cursor.execute("SELECT 1 FROM children WHERE id = ?", (child_id,))
    if not cursor.fetchone():
        conn.close()
        return jsonify({"status": "error", "message": "child not found"}), 404
    existing_row = _read_child_profile_row(cursor, child_id)
    if existing_row and isinstance(existing_row.get("skill"), dict):
        old_skill = existing_row["skill"]
        for key in (
            "observedPreferences",
            "childInitiatedNeeds",
            "trainingInsights",
            "dailyPlanPreferences",
            "eventFacts",
            "learnedSummary",
            "lastAutismEventAt",
        ):
            if key in old_skill:
                skill[key] = old_skill[key]
        if skill.get("eventFacts"):
            _refresh_skill_text_from_learned_facts(skill)
            skill["updatedAt"] = now
    if nickname:
        cursor.execute("UPDATE children SET nickname = ? WHERE id = ?", (nickname, child_id))
    cursor.execute(
        """
        INSERT INTO child_profiles
        (child_id, profile_json, skill_json, updated_at, updated_by_user_id)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(child_id) DO UPDATE SET
            profile_json = excluded.profile_json,
            skill_json = excluded.skill_json,
            updated_at = excluded.updated_at,
            updated_by_user_id = excluded.updated_by_user_id
        """,
        (
            child_id,
            json.dumps(profile, ensure_ascii=False),
            json.dumps(skill, ensure_ascii=False),
            now,
            user["id"],
        ),
    )
    conn.commit()
    row = _read_child_profile_row(cursor, child_id)
    conn.close()
    return jsonify({"status": "ok", **row}), 200


@app.route("/my/children/<int:child_id>/autism/needs/pending", methods=["GET"])
def autism_needs_pending(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    cursor.execute(
        """
        SELECT id, device_id, card_slug, label, voice_text, created_at, status
        FROM autism_child_needs
        WHERE child_id = ? AND status = 'pending'
        ORDER BY id DESC
        LIMIT 50
        """,
        (child_id,),
    )
    rows = cursor.fetchall()
    conn.close()
    items = [
        {
            "id": r[0],
            "device_id": r[1],
            "card_slug": r[2],
            "label": r[3],
            "voice_text": r[4],
            "created_at": r[5],
            "status": r[6],
        }
        for r in rows
    ]
    return jsonify({"status": "ok", "items": items}), 200


@app.route("/my/children/<int:child_id>/autism/needs/<int:need_id>/confirm", methods=["POST"])
def autism_need_confirm(child_id, need_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    cursor.execute(
        """
        UPDATE autism_child_needs
        SET status = 'confirmed', parent_confirmed_at = ?
        WHERE id = ? AND child_id = ? AND status = 'pending'
        """,
        (now, need_id, child_id),
    )
    conn.commit()
    n = cursor.rowcount
    conn.close()
    if not n:
        return jsonify({"status": "error", "message": "not found or already confirmed"}), 404
    return jsonify({"status": "ok", "id": need_id}), 200


def _autism_followup_options_for_choice(
    scene: str,
    label: str,
    focus_label: str = "",
    previous_options: list[str] | None = None,
) -> list[str]:
    label = (label or "").strip()
    focus = (focus_label or "").strip()
    target = focus if label == "都不是" and focus else label
    scene = (scene or "").strip()
    pools = {
        "害怕": ["很大的声音", "黑黑的房间", "陌生的人", "突然靠近的小动物", "看起来很高的地方"],
        "难过": ["玩具坏了", "想妈妈了", "朋友不一起玩", "被别人说了不喜欢的话", "想要的东西没有了"],
        "生气": ["玩具被拿走", "别人插队了", "声音太吵了", "事情没有按计划来", "有人碰了你的东西"],
        "开心": ["喜欢的玩具", "好吃的点心", "妈妈抱抱", "一起玩游戏", "完成了一件事"],
    }
    candidates = list(pools.get(target) or [])
    if not candidates:
        candidates = [
            f"和{target or label}有关的事情",
            "很大的声音",
            "陌生的人",
            "想休息一下",
            "不知道怎么说",
        ]
    used = {str(x or "").strip() for x in (previous_options or [])}
    candidates = [x for x in candidates if x not in used and x != "都不是"] or [
        x for x in (pools.get(target) or []) if x != "都不是"
    ] or candidates
    first_two = random.sample(candidates, k=min(2, len(candidates)))
    while len(first_two) < 2:
        first_two.append("不知道怎么说")
    return [first_two[0], first_two[1], "都不是"]


def _autism_daily_plan_alternative_options(question: str, previous_options: list[str] | None = None) -> list[str]:
    """计划表里选“都不是”时，围绕原计划问题换一组选项。"""
    q = (question or "").strip()
    used = {str(x or "").strip() for x in (previous_options or [])}
    if any(k in q for k in ("饭", "吃", "菜", "点心", "早餐", "午餐", "晚餐")):
        candidates = ["粥", "鸡蛋", "水果", "汤", "面包", "牛奶"]
    elif any(k in q for k in ("鞋", "衣", "穿", "颜色")):
        candidates = ["黄色", "绿色", "白色", "黑色", "小花", "星星"]
    elif any(k in q for k in ("玩", "游戏", "起床后")):
        candidates = ["画画", "看书", "唱歌", "玩车", "拼图", "贴纸"]
    elif any(k in q for k in ("午睡", "睡", "起床")):
        candidates = ["抱抱", "喝水", "再等一下", "上厕所", "听故事"]
    else:
        candidates = ["换一个选择", "大人帮我选", "再想一想", "稍等一下", "休息一下"]
    candidates = [x for x in candidates if x not in used]
    while len(candidates) < 2:
        candidates.append("再想一想")
    return [candidates[0], candidates[1], "都不是"]


def _autism_followup_images_for_options(options: list[str], scene: str, previous_label: str) -> dict[str, str | None]:
    images: dict[str, str | None] = {}
    for i, opt in enumerate(options):
        if opt == "都不是":
            images[f"o{i}"] = _autism_none_of_above_image_url()
            continue
        else:
            prompt = _autism_option_icon_prompt(
                opt,
                f"延续训练场景：{scene}。孩子刚选择了：{previous_label}。",
            )
        images[f"o{i}"] = _autism_square_image_url_cached(opt, prompt)
    return images


def _autism_option_image_url(opt: str, context: str) -> str | None:
    if (opt or "").strip() == "都不是":
        return _autism_none_of_above_image_url()
    return _autism_square_image_url_cached(
        chinese_label=opt,
        prompt_core_zh=_autism_option_icon_prompt(opt, context),
    )


def _autism_option_image_url_lookup(opt: str, context: str) -> str | None:
    if (opt or "").strip() == "都不是":
        return _autism_none_of_above_image_url()
    return _autism_square_image_url_lookup_cached(
        prompt_core_zh=_autism_option_icon_prompt(opt, context),
        chinese_label=opt,
    )


def _autism_audio_for_options(options: list[str], images: dict[str, str | None], prefix: str = "o") -> dict[str, str | None]:
    audio: dict[str, str | None] = {}
    for i, opt in enumerate(options):
        key = f"{prefix}{i}"
        audio[key] = _autism_label_audio_url(opt, images.get(key))
    return audio


def _training_start_enqueue_background(child_id: int, sid: int, payload: dict) -> None:
    """TTS 注入 + 设备队列写入；在独立线程中运行，HTTP 已先返回 202。

    payload 为已在请求线程中 deepcopy 的快照，勿与请求对象共享可变引用。"""
    session = {"session_id": sid, **payload}
    try:
        with app.app_context():
            queued = _enqueue_autism_session_for_child(child_id, session)
            st = "sent" if queued else "queued_no_device"
            now2 = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            conn2 = sqlite3.connect("adhd_data.db")
            cur2 = conn2.cursor()
            cur2.execute(
                """
                UPDATE autism_training_sessions SET status = ?, updated_at = ?
                WHERE id = ? AND child_id = ?
                """,
                (st, now2, sid, child_id),
            )
            conn2.commit()
            conn2.close()
            app.logger.info(
                "training/start async done session_id=%s child=%s status=%s devices=%d",
                sid,
                child_id,
                st,
                len(queued),
            )
    except Exception:
        app.logger.exception("training/start async enqueue failed session_id=%s child=%s", sid, child_id)
        try:
            nowe = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            conn3 = sqlite3.connect("adhd_data.db")
            c3 = conn3.cursor()
            c3.execute(
                """
                UPDATE autism_training_sessions SET status = ?, updated_at = ?
                WHERE id = ? AND child_id = ?
                """,
                ("enqueue_failed", nowe, sid, child_id),
            )
            conn3.commit()
            conn3.close()
        except Exception:
            app.logger.exception(
                "training/start could not persist enqueue_failed session_id=%s", sid
            )


@app.route("/my/children/<int:child_id>/autism/training/start", methods=["POST"])
def autism_training_start(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    scene_id = (data.get("scene_id") or "preference_choice").strip()
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    options = data.get("options") or []
    if not isinstance(options, list):
        options = []
    options = [str(x).strip() for x in options if str(x).strip()]
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    provided_images = data.get("images") if isinstance(data.get("images"), dict) else {}
    images: dict[str, str | None] = {}
    for i, opt in enumerate(options):
        key = f"o{i}"
        u = provided_images.get(key)
        # App 传来的本地兜底图 URL 可能指向已被清理的文件（迁服务器时只搬了 DB，
        # 没搬 server/action/*.png），原样下发会让星星机器人拉图 404。本地 URL
        # 必须校验磁盘文件，文件缺失则忽略并走重新生成。
        if isinstance(u, str) and u.startswith("http") and _autism_cached_url_is_usable(u):
            images[key] = u
        else:
            images[key] = _autism_option_image_url(opt, f"训练场景：{scene_id}")
    audio = _autism_audio_for_options(options, images)
    payload = {
        "kind": "training_start",
        "scene_id": scene_id,
        "options": options,
        "images": images,
        "audio": audio,
        "follow_up": bool(data.get("follow_up")),
        "tts_intro": (data.get("tts_intro") or "").strip(),
    }
    cursor.execute(
        """
        INSERT INTO autism_training_sessions
        (child_id, scene_id, payload_json, status, created_at, updated_at)
        VALUES (?, ?, ?, 'queued', ?, ?)
        """,
        (child_id, scene_id, json.dumps(payload, ensure_ascii=False), now, now),
    )
    sid = cursor.lastrowid
    conn.commit()
    conn.close()
    preview_ids = _xingxing_device_ids_for_child(child_id)
    threading.Thread(
        target=_training_start_enqueue_background,
        args=(child_id, sid, copy.deepcopy(payload)),
        daemon=True,
        name=f"training_start_{sid}",
    ).start()
    app.logger.info(
        "training/start accepted 202 session_id=%s child=%s scene=%s option_count=%d "
        "(TTS inject + device enqueue in background thread)",
        sid,
        child_id,
        scene_id,
        len(options),
    )
    return jsonify(
        {
            "status": "accepted",
            "session_id": sid,
            "queued_devices": preview_ids,
            "enqueue_pending": True,
            "message": "会话已创建，语音合成与入队正在后台进行，数秒至数十秒内星星将收到指令。",
        }
    ), 202


@app.route("/my/children/<int:child_id>/autism/training/assets", methods=["POST"])
def autism_training_assets(child_id):
    """预生成孩子训练场景所需图片，只写缓存/存储，不下发设备。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    scenes = data.get("scenes") or []
    if not isinstance(scenes, list) or not scenes:
        return jsonify({"status": "error", "message": "scenes required"}), 400

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    conn.close()

    prepared: dict[str, dict[str, str | None]] = {}
    expected = 0
    ready = 0
    for raw in scenes[:5]:
        if not isinstance(raw, dict):
            continue
        scene_id = (raw.get("scene_id") or "").strip() or "preference_choice"
        tts_intro = (raw.get("tts_intro") or "").strip()
        options = raw.get("options") or []
        if not isinstance(options, list):
            options = []
        clean_options = [str(x).strip() for x in options if str(x).strip()]
        scene_images: dict[str, str | None] = {}
        for i, opt in enumerate(clean_options[:4]):
            expected += 1
            key = f"o{i}"
            url = _autism_option_image_url(opt, f"训练场景：{scene_id}。引导语：{tts_intro}")
            scene_images[key] = url
            if url:
                ready += 1
        prepared[scene_id] = scene_images

    return jsonify(
        {
            "status": "ok",
            "images": prepared,
            "image_count": ready,
            "expected_count": expected,
            "ready_count": ready,
            "all_ready": expected > 0 and ready == expected,
        }
    ), 200


@app.route("/my/children/<int:child_id>/autism/training/assets/check", methods=["POST"])
def autism_training_assets_check(child_id):
    """只检查训练图片是否已有缓存；不调用智谱、不生成新图。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    scenes = data.get("scenes") or []
    if not isinstance(scenes, list) or not scenes:
        return jsonify({"status": "error", "message": "scenes required"}), 400

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    conn.close()

    prepared: dict[str, dict[str, str | None]] = {}
    expected = 0
    ready = 0
    for raw in scenes[:5]:
        if not isinstance(raw, dict):
            continue
        scene_id = (raw.get("scene_id") or "").strip() or "preference_choice"
        tts_intro = (raw.get("tts_intro") or "").strip()
        options = raw.get("options") or []
        if not isinstance(options, list):
            options = []
        clean_options = [str(x).strip() for x in options if str(x).strip()]
        scene_images: dict[str, str | None] = {}
        for i, opt in enumerate(clean_options[:4]):
            expected += 1
            key = f"o{i}"
            url = _autism_option_image_url_lookup(opt, f"训练场景：{scene_id}。引导语：{tts_intro}")
            scene_images[key] = url
            if url:
                ready += 1
        prepared[scene_id] = scene_images

    return jsonify(
        {
            "status": "ok",
            "images": prepared,
            "expected_count": expected,
            "ready_count": ready,
            "all_ready": expected > 0 and ready == expected,
        }
    ), 200


@app.route("/my/children/<int:child_id>/autism/training/status", methods=["GET"])
def autism_training_status(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    sid = request.args.get("session_id", type=int)
    if not sid:
        return jsonify({"status": "error", "message": "session_id required"}), 400
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    cursor.execute(
        """
        SELECT id, scene_id, payload_json, status, created_at, updated_at
        FROM autism_training_sessions WHERE id = ? AND child_id = ?
        """,
        (sid, child_id),
    )
    row = cursor.fetchone()
    conn.close()
    if not row:
        return jsonify({"status": "error", "message": "not found"}), 404
    return jsonify(
        {
            "status": "ok",
            "session": {
                "id": row[0],
                "scene_id": row[1],
                "payload": json.loads(row[2] or "{}"),
                "state": row[3],
                "created_at": row[4],
                "updated_at": row[5],
            },
        }
    ), 200


@app.route("/my/children/<int:child_id>/autism/daily-plan", methods=["POST"])
def autism_daily_plan(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    default_slots = [
        {
            "time": "07:00",
            "tts": "早上7点，起床啦，你喜欢穿什么颜色的鞋子？",
            "options": ["红色鞋子", "蓝色鞋子"],
        },
        {
            "time": "11:00",
            "tts": "中午11点，该吃中饭啦，你想吃什么？",
            "options": ["米饭", "面条", "饺子"],
        },
        {
            "time": "13:00",
            "tts": "下午1点，该午睡咯",
            "options": ["好的", "不好"],
        },
        {
            "time": "14:00",
            "tts": "下午2点，该起床咯，起床后你想玩什么",
            "options": ["搭积木", "滑梯", "拍皮球"],
        },
        {
            "time": "18:00",
            "tts": "晚上6点，到了吃晚饭的时候啦，你喜欢吃什么菜",
            "options": ["青菜", "胡萝卜", "肉"],
        },
    ]
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403

    data = request.json or {}
    raw_slots = data.get("slots")
    slots = []
    if isinstance(raw_slots, list):
        for i, raw in enumerate(raw_slots[:5]):
            if not isinstance(raw, dict):
                continue
            fallback = default_slots[i] if i < len(default_slots) else default_slots[-1]
            time_text = str(raw.get("time") or fallback["time"]).strip()[:8]
            tts = str(raw.get("tts") or fallback["tts"]).strip()[:300]
            raw_options = raw.get("options")
            options = []
            if isinstance(raw_options, list):
                for opt in raw_options[:4]:
                    s = str(opt or "").strip()
                    if s:
                        options.append(s[:40])
            if not options:
                options = list(fallback["options"])
            slots.append({"time": time_text, "tts": tts, "options": options})
    if len(slots) != 5:
        slots = default_slots

    provided_images = data.get("images") if isinstance(data.get("images"), dict) else {}
    images: dict[str, str | None] = {}
    for i, slot in enumerate(slots):
        for j, opt in enumerate(slot["options"]):
            key = f"s{i}_o{j}"
            u = provided_images.get(key)
            if isinstance(u, str) and u.startswith("http") and _autism_cached_url_is_usable(u):
                images[key] = u
            else:
                images[key] = _autism_option_image_url(opt, f"计划表话术：{slot['tts']}")
    audio: dict[str, str | None] = {}
    for i, slot in enumerate(slots):
        for j, opt in enumerate(slot["options"]):
            key = f"s{i}_o{j}"
            audio[key] = _autism_label_audio_url(opt, images.get(key))
    # 新计划覆盖旧计划：先清库中该孩子历史计划，再写入当前版本。
    cursor.execute("DELETE FROM autism_daily_plans WHERE child_id = ?", (child_id,))
    cursor.execute(
        """
        INSERT INTO autism_daily_plans (child_id, plan_json, images_json, created_at)
        VALUES (?, ?, ?, ?)
        """,
        (
            child_id,
            json.dumps(slots, ensure_ascii=False),
            json.dumps(images, ensure_ascii=False),
            now,
        ),
    )
    pid = cursor.lastrowid
    conn.commit()
    conn.close()
    session = {"kind": "daily_plan", "plan_id": pid, "slots": slots, "images": images, "audio": audio}
    queued = _enqueue_autism_session_for_child(child_id, session)
    return jsonify(
        {"status": "ok", "plan_id": pid, "queued_devices": queued, "images": images}
    ), 200


@app.route("/my/children/<int:child_id>/autism/daily-plan/assets", methods=["POST"])
def autism_daily_plan_assets(child_id):
    """预生成计划表图片，只写缓存/存储，不下发设备。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    raw_slots = data.get("slots") or []
    if not isinstance(raw_slots, list) or not raw_slots:
        return jsonify({"status": "error", "message": "slots required"}), 400

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    conn.close()

    images: dict[str, str | None] = {}
    count = 0
    for i, raw in enumerate(raw_slots[:5]):
        if not isinstance(raw, dict):
            continue
        tts = str(raw.get("tts") or "").strip()[:300]
        options = raw.get("options") or []
        if not isinstance(options, list):
            options = []
        for j, opt_raw in enumerate(options[:4]):
            opt = str(opt_raw or "").strip()[:40]
            if not opt:
                continue
            key = f"s{i}_o{j}"
            url = _autism_option_image_url(opt, f"计划表话术：{tts}")
            images[key] = url
            if url:
                count += 1
    return jsonify({"status": "ok", "images": images, "image_count": count}), 200


@app.route("/my/children/<int:child_id>/autism/daily-plan/assets/check", methods=["POST"])
def autism_daily_plan_assets_check(child_id):
    """只检查计划表图片是否已有缓存；不调用智谱、不生成新图。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    raw_slots = data.get("slots") or []
    if not isinstance(raw_slots, list) or not raw_slots:
        return jsonify({"status": "error", "message": "slots required"}), 400

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    conn.close()

    images: dict[str, str | None] = {}
    expected = 0
    ready = 0
    for i, raw in enumerate(raw_slots[:5]):
        if not isinstance(raw, dict):
            continue
        tts = str(raw.get("tts") or "").strip()[:300]
        options = raw.get("options") or []
        if not isinstance(options, list):
            options = []
        for j, opt_raw in enumerate(options[:4]):
            opt = str(opt_raw or "").strip()[:40]
            if not opt:
                continue
            expected += 1
            key = f"s{i}_o{j}"
            url = _autism_option_image_url_lookup(opt, f"计划表话术：{tts}")
            images[key] = url
            if url:
                ready += 1
    return jsonify(
        {
            "status": "ok",
            "images": images,
            "expected_count": expected,
            "ready_count": ready,
            "all_ready": expected > 0 and ready == expected,
        }
    ), 200


@app.route("/my/children/<int:child_id>/autism/images", methods=["POST"])
def autism_images_one(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    prompt = (data.get("prompt") or "").strip()
    if not prompt:
        return jsonify({"status": "error", "message": "prompt required"}), 400
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    conn.close()
    label = (prompt[:80] or "配图").strip() or "配图"
    url = _autism_square_image_url_cached(chinese_label=label, prompt_core_zh=prompt)
    if url:
        return jsonify({"status": "ok", "url": url}), 200
    return jsonify({"status": "error", "message": "image generation failed"}), 502


@app.route("/device/<device_id>/autism/need-event", methods=["POST"])
def device_autism_need_event(device_id):
    """星星机器人上报「孩子需求确认」事件（无需登录，凭已绑定 device 校验）。"""
    device_id = _normalize_device_id(device_id)
    if not _ESP32_DEVICE_ID_RE.match(device_id):
        return jsonify({"status": "error", "message": "invalid device_id"}), 400
    info = _get_esp32_device(device_id)
    if not info or info.get("child_id") is None:
        return jsonify({"status": "error", "message": "device not bound"}), 404
    child_id = int(info["child_id"])
    data = request.json or {}
    slug = (data.get("card_slug") or "").strip()
    label = (data.get("label") or "").strip()
    voice = (data.get("voice_text") or label).strip()
    if not label:
        return jsonify({"status": "error", "message": "label required"}), 400
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        INSERT INTO autism_child_needs
        (child_id, device_id, card_slug, label, voice_text, created_at, status)
        VALUES (?, ?, ?, ?, ?, ?, 'pending')
        """,
        (child_id, device_id, slug or None, label, voice, now),
    )
    nid = cursor.lastrowid
    _enrich_child_skill_from_autism_event(
        cursor,
        child_id,
        kind="child_initiated_need",
        label=label,
        source="child_initiated",
        scene=slug or "need",
        ts=now,
        payload={"voice_text": voice},
    )
    conn.commit()
    conn.close()
    return jsonify({"status": "ok", "need_id": nid, "child_id": child_id}), 200


@app.route("/my/children/<int:child_id>/autism/events/training", methods=["POST"])
def autism_events_training(child_id):
    """家长端或脚本上报训练阶段事件（与设备上报 schema 对齐）。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    scene = (data.get("scene") or "").strip() or "unknown"
    phase = (data.get("phase") or "").strip() or "unknown"
    payload = data.get("payload")
    ts = (data.get("ts") or "").strip() or datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    pj = json.dumps(payload, ensure_ascii=False) if payload is not None else "{}"
    sid_i = _session_id_from_json(data.get("session_id"))
    cursor.execute(
        """
        INSERT INTO autism_training_events
        (child_id, device_id, scene, phase, payload_json, ts, created_at, session_id)
        VALUES (?, NULL, ?, ?, ?, ?, ?, ?)
        """,
        (child_id, scene, phase, pj, ts, now, sid_i),
    )
    eid = cursor.lastrowid
    if phase == "image_confirmed" and isinstance(payload, dict):
        _enrich_child_skill_from_autism_event(
            cursor,
            child_id,
            kind="training_choice",
            label=payload.get("label"),
            source=payload.get("source") or "parent_training_event",
            scene=scene,
            ts=ts,
            payload=payload,
        )
    if sid_i is not None:
        cursor.execute(
            """
            UPDATE autism_training_sessions SET status = ?, updated_at = ?
            WHERE id = ? AND child_id = ?
            """,
            (f"phase:{phase}", now, sid_i, child_id),
        )
    conn.commit()
    conn.close()
    return jsonify({"status": "ok", "event_id": eid}), 200


@app.route("/my/children/<int:child_id>/autism/events/training", methods=["GET"])
def autism_events_training_list(child_id):
    """家长端增量拉取训练/日常计划事件，用于手机震动提示与报告数据展示。"""
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    after_id = request.args.get("after_id", default=0, type=int) or 0
    limit = min(max(request.args.get("limit", default=30, type=int) or 30, 1), 100)
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    cursor.execute(
        """
        SELECT id, device_id, scene, phase, payload_json, ts, created_at, session_id
        FROM autism_training_events
        WHERE child_id = ? AND id > ?
        ORDER BY id ASC
        LIMIT ?
        """,
        (child_id, after_id, limit),
    )
    rows = cursor.fetchall()
    conn.close()
    items = []
    for row in rows:
        eid = row[0]
        device_id = row[1]
        scene = row[2]
        phase = row[3]
        payload_json = row[4]
        ts = row[5]
        created_at = row[6]
        session_id_ev = row[7] if len(row) > 7 else None
        try:
            payload = json.loads(payload_json or "{}")
        except Exception:
            payload = {}
        items.append(
            {
                "id": eid,
                "device_id": device_id,
                "scene": scene,
                "phase": phase,
                "payload": payload,
                "ts": ts,
                "created_at": created_at,
                "session_id": session_id_ev,
            }
        )
    return jsonify({"status": "ok", "items": items}), 200


@app.route("/device/<device_id>/autism/training-event", methods=["POST"])
def device_autism_training_event(device_id):
    """星星机器人上报训练阶段 / 完成事件。"""
    device_id = _normalize_device_id(device_id)
    if not _ESP32_DEVICE_ID_RE.match(device_id):
        return jsonify({"status": "error", "message": "invalid device_id"}), 400
    info = _get_esp32_device(device_id)
    if not info or info.get("child_id") is None:
        return jsonify({"status": "error", "message": "device not bound"}), 404
    child_id = int(info["child_id"])
    data = request.json or {}
    scene = (data.get("scene") or "").strip() or "unknown"
    phase = (data.get("phase") or "").strip() or "unknown"
    payload = data.get("payload")
    ts = (data.get("ts") or "").strip() or datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    sid_i = _session_id_from_json(data.get("session_id"))
    pj = json.dumps(payload, ensure_ascii=False) if payload is not None else "{}"
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        """
        INSERT INTO autism_training_events
        (child_id, device_id, scene, phase, payload_json, ts, created_at, session_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (child_id, device_id, scene, phase, pj, ts, now, sid_i),
    )
    eid = cursor.lastrowid
    if phase == "image_confirmed" and isinstance(payload, dict):
        _enrich_child_skill_from_autism_event(
            cursor,
            child_id,
            kind="training_choice",
            label=payload.get("label"),
            source=payload.get("source") or "device_training_event",
            scene=scene,
            ts=ts,
            payload=payload,
        )
    if sid_i is not None:
        cursor.execute(
            """
            UPDATE autism_training_sessions SET status = ?, updated_at = ?
            WHERE id = ? AND child_id = ?
            """,
            (f"phase:{phase}", now, sid_i, child_id),
        )
    conn.commit()
    conn.close()

    if phase == "image_confirmed" and isinstance(payload, dict):
        app_training = (
            sid_i is not None
            and _autism_payload_is_app_child_training(payload, scene)
        )
        # 单次预设日常训练：不在云端排队追问/换组图；鼓励与结束语由固件 TTS。
        if app_training:
            return jsonify({"status": "ok", "event_id": eid, "child_id": child_id}), 200
        label = str(payload.get("label") or "").strip()
        if label:
            payload_kind = str(payload.get("kind") or "").strip()
            payload_source = str(payload.get("source") or "").strip()
            focus_label = str(payload.get("focus_label") or "").strip()
            previous_options = payload.get("options") if isinstance(payload.get("options"), list) else []
            is_daily_plan_choice = (
                payload_kind == "daily_plan"
                or payload_source == "daily_plan"
                or scene == "daily_plan"
            )
            if is_daily_plan_choice and label != "都不是":
                return jsonify({"status": "ok", "event_id": eid, "child_id": child_id}), 200
            if is_daily_plan_choice:
                options = _autism_daily_plan_alternative_options(focus_label, previous_options)
                image_context = focus_label or "计划表"
                tts_intro = "好，我们换一组继续看。你更想选哪个？"
            else:
                if label != "都不是":
                    focus_label = label
                options = _autism_followup_options_for_choice(scene, label, focus_label, previous_options)
                image_context = focus_label or label
                if label == "都不是":
                    tts_intro = "好，我们换一组继续看。哪个更像呢？"
                else:
                    tts_intro = f"我们看看，是什么让你觉得{label}？"
            images = _autism_followup_images_for_options(options, scene, image_context)
            audio = _autism_audio_for_options(options, images)
            followup = {
                "kind": "training_start",
                "scene_id": scene or "follow_up",
                "focus_label": focus_label,
                "options": options,
                "images": images,
                "audio": audio,
                "follow_up": True,
                "tts_intro": tts_intro,
            }
            queued = _enqueue_autism_session_for_child(child_id, followup)
            app.logger.info(
                "autism follow-up queued child=%s scene=%s label=%s targets=%s options=%s",
                child_id, scene, label, queued, options,
            )
    return jsonify({"status": "ok", "event_id": eid, "child_id": child_id}), 200


@app.route("/my/children/<int:child_id>/skill", methods=["GET"])
def my_child_skill_get(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    row = _read_child_profile_row(cursor, child_id)
    if not row:
        conn.close()
        return jsonify({"status": "error", "message": "child not found"}), 404
    context = _recent_child_skill_context(cursor, child_id)
    conn.close()
    return jsonify(
        {
            "status": "ok",
            "child_id": child_id,
            "profile": row["profile"],
            "skill": row["skill"],
            "recent_context": context,
        }
    ), 200


@app.route("/my/children/<int:child_id>/skill/chat", methods=["POST"])
def my_child_skill_chat(child_id):
    user = _get_request_user()
    if not user:
        return jsonify({"status": "error", "message": "unauthorized"}), 401
    data = request.json or {}
    question = _compact_text(data.get("question"), 300)
    if not question:
        return jsonify({"status": "error", "message": "question required"}), 400
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    if not _user_can_access_child(cursor, user["id"], child_id):
        conn.close()
        return jsonify({"status": "error", "message": "forbidden"}), 403
    row = _read_child_profile_row(cursor, child_id)
    if not row:
        conn.close()
        return jsonify({"status": "error", "message": "child not found"}), 404
    context = _recent_child_skill_context(cursor, child_id)
    conn.close()
    answer = _fixed_child_skill_answer(question, row["profile"], row["skill"], context)
    source = "template"
    if not answer:
        answer = fetch_kimi_child_skill_answer(question, row["profile"], row["skill"], context)
        source = "kimi"
    return jsonify(
        {
            "status": "ok",
            "child_id": child_id,
            "question": question,
            "answer": answer,
            "source": source,
        }
    ), 200


@app.route("/teacher/threshold_suggest", methods=["POST"])
def teacher_threshold_suggest():
    data = request.json or {}
    profile = data.get("profile") if isinstance(data.get("profile"), dict) else {}
    current_rule = (
        data.get("current_rule") if isinstance(data.get("current_rule"), dict) else {}
    )
    if not profile:
        return jsonify({"status": "error", "message": "profile required"}), 400
    suggestion = fetch_kimi_teacher_threshold_suggestion(profile, current_rule)
    return jsonify({"status": "ok", **suggestion}), 200


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


def _esp32_device_role(kind: str | None) -> str:
    """Normalize stored kind strings into the three ESP32 roles we support."""
    k = (kind or "").strip().lower()
    if not k:
        return "unknown"
    if k == "xingxing" or "autism" in k or "孤独" in k:
        return "autism_star"
    if k == "xiaozhi" or "xiaozhi-esp32-2.2.4" in k or "adhd-star" in k or "多动" in k:
        return "adhd_star"
    if "esp32-s3-lcd-1.47b" in k or "lcd" in k or "plush" in k or "毛绒" in k:
        return "plush"
    return "unknown"


def _xiaozhi_device_ids_for_child(child_id: int) -> list[str]:
    """挑出该孩子绑定的多动症星星机器人 device_id 列表。

    三类 ESP32 设备**绝对不能搞混**：

      * 毛绒球 `ESP32-S3-LCD-1.47B`：固件 announce 写 `kind='esp32-s3-lcd-1.47B'`，
        Flutter 端 bind 时不带 kind。它走 LED 呼吸命令，**不能**收到 `xiaozhi_invoke_chat`。
      * 多动症星星机器人 `xiaozhi-esp32-2.2.4`：用于 submit_log 后的主动陪聊。
      * 孤独症星星机器人 `xingxing`：只用于孤独症训练 / 计划表视觉选择。

    选择策略（按优先级）：
      1) 严格：`kind` 归一化为 `adhd_star` —— 99% 的情况落在这里。
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

    strict = [r[0] for r in rows if _esp32_device_role(r[1]) == "adhd_star"]
    if strict:
        return strict

    # 仅在严格无命中时，回退到「绑定了但 announce 从未上送 kind」的行；明确
    # 已写为毛绒球家族字面值的行不会被纳入。
    relaxed = [r[0] for r in rows if _esp32_device_role(r[1]) == "unknown"]
    if relaxed:
        app.logger.warning(
            "xiaozhi target lookup: no strict kind=xiaozhi match for child_id=%s; "
            "falling back to %d device(s) with NULL kind: %s (all rows=%s). "
            "If you actually have an ADHD xiaozhi bound, power-cycle it once so its "
            "announce writes kind='xiaozhi-esp32-2.2.4'.",
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


def _xingxing_device_ids_for_child(child_id: int) -> list[str]:
    """挑出该孩子绑定的孤独症星星机器人 device_id 列表。"""
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
    ids = [r[0] for r in rows if _esp32_device_role(r[1]) == "autism_star"]
    if not ids:
        app.logger.warning(
            "xingxing target lookup: child_id=%s has no bound autism xingxing device. rows=%s",
            child_id, [(r[0], r[1]) for r in rows],
        )
    return ids


# 智谱文生图：统一追加扁平矢量儿童图标风格；输出经 240×240 中心裁剪后先备份到本地
# server/action 目录，再上传腾讯云 COS `action/`，并以完整 prompt 哈希缓存避免重复生成。
# 与 assets/action 下手工参考图对齐：minimalist + soft pastel + solid bg + bold lines + no text；
# 仍保留「底部留白条供服务端叠字、单主体约 80%」等约束，避免破坏裁切与标签逻辑。
_IMAGE_STYLE_SUFFIX_ZHIPU = (
    " A minimalist 2D flat vector icon, cute style, child-friendly, soft pastel colors, "
    "solid clean background; prefer a soft warm peach or pale apricot-orange fill as the default mood "
    "(still flat and simple, not textured), unless a slightly different pastel would keep the subject clearer. "
    "Bold clean lines, no complex details, no text. "
    "One clear focal subject only; very large and centered, filling about 80 percent of the square; "
    "simple recognizable shapes, no photorealism, no tiny facial detail. "
    "Leave a clean empty label band at the bottom for overlay text; "
    "do not generate any letters, numbers, watermark, or signature. "
    "Perfect square composition. --ar 1:1"
)


def _autism_option_icon_prompt(label: str, context: str = "") -> str:
    """给训练/计划表选项生图的统一 prompt：重点只画选项本身，避免被整句上下文带偏。"""
    clean_label = _compact_text(label, 40)
    clean_context = _compact_text(context, 120)
    if clean_context:
        return (
            f"只画一个清晰可识别的「{clean_label}」儿童选择卡片图标。"
            f"主体必须是：{clean_label}。"
            f"上下文仅供理解，不要画上下文里的其他物品或人物：{clean_context}。"
            "单一主体，居中，主体占画面至少80%，正方形构图，背景是治愈色淡淡的橙色。"
            "底部预留干净标签区域，不要自己写任何文字。"
        )
    return (
        f"只画一个清晰可识别的「{clean_label}」儿童选择卡片图标。"
        f"主体必须是：{clean_label}。单一主体，居中，主体占画面至少80%，"
        "正方形构图，背景是治愈色淡淡的橙色。底部预留干净标签区域，不要自己写任何文字。"
    )


def _autism_public_base_url() -> str:
    """星星拉图的绝对 URL 前缀（设备侧需可访问）。未设置时默认本机端口。"""
    configured = os.getenv("FLASK_PUBLIC_BASE_URL") or os.getenv("AUTISM_IMAGE_PUBLIC_BASE")
    if configured:
        return configured.rstrip("/")
    if has_request_context():
        # 不能把 127.0.0.1 下发给 ESP32；优先沿用手机访问 Flask 的 Host/IP。
        return request.host_url.rstrip("/")
    return "http://127.0.0.1:11760"


def _autism_action_image_url(filename: str) -> str:
    return f"{_autism_public_base_url()}/autism/action-images/{quote(filename, safe='')}"


def _autism_action_audio_url(filename: str) -> str:
    return f"{_autism_public_base_url()}/autism/action-audio/{quote(filename, safe='')}"


def _http_download_bytes(url: str, timeout: int = 90) -> bytes | None:
    try:
        import requests as req_lib

        r = req_lib.get(url, timeout=timeout)
        if r.status_code != 200 or not r.content:
            app.logger.warning("download image %s -> %s", url[:120], r.status_code)
            return None
        return r.content
    except Exception as e:
        app.logger.warning("download image error: %s", e)
        return None


def _autism_label_font(size: int):
    from PIL import ImageFont

    candidates = [
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "/usr/share/fonts/truetype/arphic/ukai.ttc",
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simhei.ttf",
        "C:/Windows/Fonts/simsun.ttc",
    ]
    for path in candidates:
        try:
            if os.path.isfile(path):
                return ImageFont.truetype(path, size=size)
        except Exception:
            continue
    return ImageFont.load_default()


def _png_bytes_240_square(raw: bytes, label: str = "") -> bytes | None:
    """将智谱返回图裁成 240×240，并在底部用服务端字体叠加中文标签。"""
    try:
        from io import BytesIO

        from PIL import Image, ImageDraw

        im = Image.open(BytesIO(raw))
        im = im.convert("RGBA")
        w, h = im.size
        if w <= 0 or h <= 0:
            return None
        side = min(w, h)
        left = (w - side) // 2
        top = (h - side) // 2
        im = im.crop((left, top, left + side, top + side))
        im = im.resize((240, 240), Image.Resampling.LANCZOS)

        clean_label = (label or "").strip()
        if clean_label:
            band_h = 34
            draw = ImageDraw.Draw(im)
            draw.rectangle((0, 240 - band_h, 240, 240), fill=(255, 238, 216, 255))
            font_size = 24 if len(clean_label) <= 4 else 20
            font = _autism_label_font(font_size)
            bbox = draw.textbbox((0, 0), clean_label, font=font)
            tw = bbox[2] - bbox[0]
            th = bbox[3] - bbox[1]
            x = max(0, (240 - tw) // 2)
            y = 240 - band_h + max(0, (band_h - th) // 2) - 2
            draw.text((x, y), clean_label, fill=(0, 0, 0, 255), font=font)

        buf = BytesIO()
        im.save(buf, format="PNG", optimize=True)
        return buf.getvalue()
    except Exception as e:
        app.logger.warning("autism image 240 resize error: %s", e)
        return None


def _autism_none_of_above_image_url() -> str | None:
    """确定性生成“都不是”选择卡，避免文生图漏画红叉。"""
    label = "都不是"
    short = hashlib.sha256(b"autism-none-of-above-red-cross-v2").hexdigest()[:8]
    filename = f"{label}_{short}.png"
    local_path = os.path.join(_AUTISM_LOCAL_IMAGE_STORE, filename)
    if os.path.isfile(local_path):
        return _autism_action_image_url(filename)
    try:
        from PIL import Image, ImageDraw

        os.makedirs(_AUTISM_LOCAL_IMAGE_STORE, exist_ok=True)
        im = Image.new("RGBA", (240, 240), (255, 238, 216, 255))
        draw = ImageDraw.Draw(im)
        band_h = 34

        draw.ellipse((42, 24, 198, 180), fill=(255, 255, 255, 255), outline=(210, 130, 92, 255), width=6)
        draw.line((78, 62, 162, 146), fill=(220, 20, 20, 255), width=18)
        draw.line((162, 62, 78, 146), fill=(220, 20, 20, 255), width=18)

        draw.rectangle((0, 240 - band_h, 240, 240), fill=(255, 238, 216, 255))
        font = _autism_label_font(24)
        bbox = draw.textbbox((0, 0), label, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        draw.text(((240 - tw) // 2, 240 - band_h + (band_h - th) // 2 - 2), label, fill=(0, 0, 0, 255), font=font)

        im.save(local_path, format="PNG", optimize=True)
        app.logger.info("autism none-of-above image saved: %s", local_path)
        return _autism_action_image_url(filename)
    except Exception as e:
        app.logger.warning("autism none-of-above image failed: %s", e)
        return None


def _zhipu_raw_image_temp_url(full_prompt: str) -> str | None:
    """调用智谱 CogView，返回临时 URL（未裁切）。"""
    key = (os.getenv("GLM_API_KEY") or "").strip()
    if not key:
        return None
    try:
        import requests as req_lib

        body = {
            "model": "cogview-3-flash",
            "prompt": (full_prompt or "")[:1800],
            "size": "1024x1024",
        }
        r = req_lib.post(
            "https://open.bigmodel.cn/api/paas/v4/images/generations",
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
            },
            json=body,
            timeout=120,
        )
        if r.status_code != 200:
            app.logger.warning("zhipu image %s: %s", r.status_code, r.text[:500])
            return None
        data = r.json()
        arr = data.get("data") or []
        if not arr:
            return None
        u = (arr[0] or {}).get("url")
        return u if isinstance(u, str) and u.startswith("http") else None
    except Exception as e:
        app.logger.warning("zhipu image error: %s", e)
        return None


def _cos_put_action_png(object_key: str, png_bytes: bytes) -> str | None:
    """上传到腾讯云 COS，返回可公网访问的 URL；未配置密钥时返回 None。"""
    sid = (os.getenv("TENCENT_COS_SECRET_ID") or "").strip()
    sk = (os.getenv("TENCENT_COS_SECRET_KEY") or "").strip()
    region = (os.getenv("TENCENT_COS_REGION") or "").strip()
    bucket = (os.getenv("TENCENT_COS_BUCKET") or "").strip()
    if not (sid and sk and region and bucket):
        return None
    try:
        from qcloud_cos import CosConfig
        from qcloud_cos import CosS3Client
    except ImportError:
        app.logger.warning("cos-python-sdk-v5 not installed; pip install cos-python-sdk-v5")
        return None
    try:
        cfg = CosConfig(Region=region, SecretId=sid, SecretKey=sk, Scheme="https")
        client = CosS3Client(cfg)
        client.put_object(
            Bucket=bucket,
            Body=png_bytes,
            Key=object_key,
            ContentType="image/png",
        )
    except Exception as e:
        app.logger.warning("COS put_object failed: %s", e)
        return None
    base = (os.getenv("TENCENT_COS_PUBLIC_URL_BASE") or "").rstrip("/")
    if base:
        return f"{base}/{object_key}"
    return f"https://{bucket}.cos.{region}.myqcloud.com/{object_key}"


def _autism_image_cache_key(prompt_core_zh: str, fallback_label: str = "配图") -> tuple[str, str]:
    core = " ".join((prompt_core_zh or "").strip().split())
    if not core:
        core = " ".join((fallback_label or "配图").split()) or "配图"
    full_prompt = core + _IMAGE_STYLE_SUFFIX_ZHIPU
    if len(full_prompt) > 2000:
        full_prompt = full_prompt[:2000]
    return hashlib.sha256(full_prompt.encode("utf-8")).hexdigest(), full_prompt


def _autism_local_image_url_by_label(label: str) -> str | None:
    """兜底：DB 记录缺失时，按 server/action 文件名包含中文标签来找已有备份图。"""
    label = (label or "").strip()
    if not label:
        return None
    try:
        if not os.path.isdir(_AUTISM_LOCAL_IMAGE_STORE):
            return None
        candidates = []
        for fn in os.listdir(_AUTISM_LOCAL_IMAGE_STORE):
            if not fn.lower().endswith(".png"):
                continue
            if label in fn:
                path = os.path.join(_AUTISM_LOCAL_IMAGE_STORE, fn)
                candidates.append((os.path.getmtime(path), fn))
        if not candidates:
            return None
        candidates.sort(reverse=True)
        return _autism_action_image_url(candidates[0][1])
    except Exception as e:
        app.logger.warning("autism image local lookup by label failed: %s", e)
        return None


def _autism_rewrite_local_image_url(url: str | None) -> str | None:
    if not isinstance(url, str) or not url:
        return None
    marker = "/autism/action-images/"
    pos = url.find(marker)
    if pos < 0:
        return url
    filename = _autism_normalize_action_image_filename(url[pos + len(marker):].split("?", 1)[0].split("#", 1)[0])
    return _autism_action_image_url(filename)


def _autism_synthesize_ogg(text: str, audio_path: str) -> bool:
    """edge-tts 合成中文 → 转 24k 单声道 OGG/Opus 落盘到 audio_path。成功返回 True。"""
    text = (text or "").strip()
    if not text:
        return False
    try:
        import asyncio
        import subprocess
        import tempfile
        import edge_tts
        from xiaozhi_bridge import _ffmpeg_bin

        ffmpeg_exe = _ffmpeg_bin()
        if ffmpeg_exe is None:
            app.logger.warning("autism tts ogg skipped: ffmpeg not found")
            return False
        os.makedirs(_AUTISM_LOCAL_IMAGE_STORE, exist_ok=True)
        fd_mp3, mp3 = tempfile.mkstemp(suffix=".mp3")
        os.close(fd_mp3)
        try:
            async def _run() -> None:
                comm = edge_tts.Communicate(
                    text, os.getenv("XIAOZHI_TTS_VOICE", "zh-CN-XiaoxiaoNeural")
                )
                await comm.save(mp3)

            asyncio.run(_run())
            subprocess.run(
                [
                    ffmpeg_exe, "-y", "-i", mp3,
                    "-c:a", "libopus", "-b:a", "24k", "-ar", "24000", "-ac", "1",
                    audio_path,
                ],
                check=True,
                capture_output=True,
            )
        finally:
            try:
                os.remove(mp3)
            except OSError:
                pass
        return True
    except Exception as e:
        app.logger.warning("autism tts ogg failed: %s", e)
        return False


def _autism_tts_ogg_url(text: str) -> str | None:
    """把任意中文文案（开场白 / 鼓励语）预合成成可外放的本地 OGG，返回公开 URL。

    与图片标签音频走同一目录 / 路由（/autism/action-audio/<fn>），设备直接
    PlaySound，不经 LLM / 麦克风 / 主动开场匹配，确定能播、内容固定。
    文件名按文本 md5 缓存，相同文案复用同一文件。"""
    text = (text or "").strip()
    if not text:
        return None
    audio_fn = "tts_" + hashlib.md5(text.encode("utf-8")).hexdigest()[:16] + ".ogg"
    audio_path = os.path.join(_AUTISM_LOCAL_IMAGE_STORE, audio_fn)
    if os.path.isfile(audio_path):
        return _autism_action_audio_url(audio_fn)
    if _autism_synthesize_ogg(text, audio_path):
        app.logger.info("autism tts ogg saved: %s", audio_path)
        return _autism_action_audio_url(audio_fn)
    return None


def _autism_label_audio_url(label: str, image_url: str | None) -> str | None:
    """为图片生成同名 OGG 标签音频，如 害怕_xxxx.png -> 害怕_xxxx.ogg。"""
    label = (label or "").strip()
    if not label or not isinstance(image_url, str):
        return None
    marker = "/autism/action-images/"
    pos = image_url.find(marker)
    if pos < 0:
        return None
    image_fn = image_url[pos + len(marker):].split("?", 1)[0].split("#", 1)[0]
    image_fn = _autism_normalize_action_image_filename(image_fn)
    if not image_fn.lower().endswith(".png"):
        return None
    audio_fn = image_fn[:-4] + ".ogg"
    if ".." in audio_fn or "/" in audio_fn or "\\" in audio_fn:
        return None
    audio_path = os.path.join(_AUTISM_LOCAL_IMAGE_STORE, audio_fn)
    if os.path.isfile(audio_path):
        return _autism_action_audio_url(audio_fn)
    if _autism_synthesize_ogg(label, audio_path):
        app.logger.info("autism label audio saved: %s", audio_path)
        return _autism_action_audio_url(audio_fn)
    return None


def _autism_cached_url_is_usable(url: str | None) -> bool:
    """缓存命中的 URL 是否真的可拉取。

    仅本地兜底图（/autism/action-images/<fn>）需要校验磁盘文件是否存在——
    DB 记录在、文件却被迁移/清理掉时，星星机器人会拿到 404。COS/CDN 等远程
    URL 无法在此廉价校验，按可用处理。
    """
    if not isinstance(url, str) or not url:
        return False
    marker = "/autism/action-images/"
    pos = url.find(marker)
    if pos < 0:
        return True  # 远程 URL（如腾讯云 COS），无法本地校验，视为可用
    fn = _autism_normalize_action_image_filename(
        url[pos + len(marker):].split("?", 1)[0].split("#", 1)[0]
    )
    if not fn or ".." in fn or "/" in fn or "\\" in fn:
        return False
    return os.path.isfile(os.path.join(_AUTISM_LOCAL_IMAGE_STORE, fn))


def _prune_stale_autism_image_cache() -> None:
    """启动自检：删除所有指向缺失本地文件的图片缓存记录。

    迁服务器时常只搬了 adhd_data.db、没搬 server/action/*.png，导致 DB 命中却
    404。开机时一次性清掉这些死记录，之后首次用到会重新生成（需配 GLM_API_KEY）。
    COS/CDN 等远程 URL 无法廉价校验，保留不动。
    """
    try:
        conn = sqlite3.connect("adhd_data.db")
        cursor = conn.cursor()
        cursor.execute("SELECT cache_key, public_url FROM autism_image_cache")
        rows = cursor.fetchall()
        stale_keys = [
            ck for ck, url in rows if not _autism_cached_url_is_usable(url)
        ]
        if stale_keys:
            cursor.executemany(
                "DELETE FROM autism_image_cache WHERE cache_key = ?",
                [(ck,) for ck in stale_keys],
            )
            conn.commit()
        conn.close()
        if stale_keys:
            print(
                f"⚠️  图片缓存自检：清理 {len(stale_keys)}/{len(rows)} 条指向缺失"
                f"本地文件的记录（store={_AUTISM_LOCAL_IMAGE_STORE}）"
            )
        else:
            print(f"✅ 图片缓存自检：{len(rows)} 条记录均有效")
    except sqlite3.OperationalError:
        # autism_image_cache 表尚未创建（首次启动）等情况，忽略即可。
        pass
    except Exception as e:
        print(f"图片缓存自检失败（忽略，不影响启动）：{e}")


_prune_stale_autism_image_cache()


def _autism_square_image_url_lookup_cached(prompt_core_zh: str, chinese_label: str = "") -> str | None:
    """只查询已缓存的 240x240 图片 URL；不会调用智谱生成新图。"""
    ck, full_prompt = _autism_image_cache_key(prompt_core_zh, chinese_label or "配图")
    app.logger.info("ZHIPU_IMAGE_PROMPT_CHECK label=%s prompt=%s", chinese_label, full_prompt)
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        "SELECT public_url FROM autism_image_cache WHERE cache_key = ?",
        (ck,),
    )
    row = cursor.fetchone()
    if row and row[0]:
        cached = _autism_rewrite_local_image_url(row[0])
        if _autism_cached_url_is_usable(cached):
            conn.close()
            return cached
    label = (chinese_label or "").strip()
    if label:
        cursor.execute(
            """
            SELECT public_url FROM autism_image_cache
            WHERE label_zh = ?
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (label,),
        )
        row = cursor.fetchone()
    conn.close()
    if row and row[0]:
        cached = _autism_rewrite_local_image_url(row[0])
        if _autism_cached_url_is_usable(cached):
            return cached
    return _autism_local_image_url_by_label(label)


def _autism_square_image_url_cached(chinese_label: str, prompt_core_zh: str) -> str | None:
    """按完整 prompt（含固定英文风格）做缓存；中文 label 用于 COS/本地文件名。

    环境变量（腾讯云）：
      TENCENT_COS_SECRET_ID / TENCENT_COS_SECRET_KEY / TENCENT_COS_REGION / TENCENT_COS_BUCKET
      TENCENT_COS_ACTION_PREFIX  默认 action  （对象键前缀，即 action/xxx.png）
      TENCENT_COS_PUBLIC_URL_BASE  可选，CDN 或自定义域名，须不含末尾 /
    公网访问 Flask 本地兜底图：
      FLASK_PUBLIC_BASE_URL 或 AUTISM_IMAGE_PUBLIC_BASE（含端口），默认 http://127.0.0.1:11760
    """
    label = (chinese_label or "").strip() or "配图"
    ck, full_prompt = _autism_image_cache_key(prompt_core_zh, label)
    app.logger.info("ZHIPU_IMAGE_PROMPT label=%s prompt=%s", label, full_prompt)
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    cursor.execute(
        "SELECT public_url FROM autism_image_cache WHERE cache_key = ?",
        (ck,),
    )
    row = cursor.fetchone()
    if row and row[0]:
        cached = _autism_rewrite_local_image_url(row[0])
        if _autism_cached_url_is_usable(cached):
            conn.close()
            return cached
        # DB 有记录但本地文件已丢失：删掉死记录，落到下面重新生成。
        app.logger.warning(
            "autism image cache stale (file missing), regenerating: %s", cached
        )
        try:
            cursor.execute(
                "DELETE FROM autism_image_cache WHERE cache_key = ?", (ck,)
            )
            conn.commit()
        except Exception as e:
            app.logger.warning("autism image cache cleanup failed: %s", e)
    conn.close()

    tmp_url = _zhipu_raw_image_temp_url(full_prompt)
    if not tmp_url:
        return None
    raw = _http_download_bytes(tmp_url)
    if not raw:
        return None
    png = _png_bytes_240_square(raw, label)
    if not png:
        return None

    short = ck[:8]
    # ESP32 HTTP client may send non-ASCII path bytes without percent-encoding.
    # Keep generated local filenames ASCII-only so image URLs are robust.
    stem = re.sub(r"[^0-9A-Za-z\u4e00-\u9fff._-]+", "_", label).strip("._")[:60] or "img"
    filename = f"{stem}_{short}.png"
    prefix = (os.getenv("TENCENT_COS_ACTION_PREFIX") or "action").strip("/").strip() or "action"
    cos_object_key = f"{prefix}/{filename}"

    # 无论是否配置腾讯云 COS，都先在 server/action 落一份本地备份，满足"先备份、可复用"。
    try:
        os.makedirs(_AUTISM_LOCAL_IMAGE_STORE, exist_ok=True)
        local_path = os.path.join(_AUTISM_LOCAL_IMAGE_STORE, filename)
        with open(local_path, "wb") as f:
            f.write(png)
        app.logger.info("autism image backup saved: %s", local_path)
    except Exception as e:
        app.logger.warning("autism image local backup failed: %s", e)

    public_url = _cos_put_action_png(cos_object_key, png)
    stored_cos_key = cos_object_key
    if not public_url:
        public_url = _autism_action_image_url(filename)
        stored_cos_key = f"local:{filename}"
        app.logger.info("autism image served locally (configure COS for Tencent Cloud): %s", filename)

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            INSERT INTO autism_image_cache (cache_key, label_zh, cos_key, public_url, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (ck, label, stored_cos_key, public_url, now),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        conn.rollback()
        cursor.execute(
            "SELECT public_url FROM autism_image_cache WHERE cache_key = ?",
            (ck,),
        )
        row2 = cursor.fetchone()
        if row2 and row2[0]:
            public_url = _autism_rewrite_local_image_url(row2[0])
    finally:
        conn.close()
    return public_url


@app.route("/diag/glm-image", methods=["GET"])
def diag_glm_image():
    """快速自检智谱生图全链路：Key 是否生效、智谱是否返图、240×240 裁切、落盘/COS。

    用法（浏览器或 curl 即可）：
      GET /diag/glm-image                 用默认提示词「起床」
      GET /diag/glm-image?prompt=洗手&label=洗手
    返回 JSON，逐步标注每一环节成功与否，方便定位失败点。
    """
    label = (request.args.get("label") or request.args.get("prompt") or "起床").strip()
    core = (request.args.get("prompt") or label).strip()

    key = (os.getenv("GLM_API_KEY") or "").strip()
    steps: dict = {
        "glm_api_key_present": bool(key),
        "glm_api_key_len": len(key),
        "glm_endpoint": "https://open.bigmodel.cn/api/paas/v4/images/generations",
        "model": "cogview-3-flash",
        "cos_configured": all(
            (os.getenv(k) or "").strip()
            for k in (
                "TENCENT_COS_SECRET_ID",
                "TENCENT_COS_SECRET_KEY",
                "TENCENT_COS_REGION",
                "TENCENT_COS_BUCKET",
            )
        ),
        "local_store_dir": _AUTISM_LOCAL_IMAGE_STORE,
    }
    if not key:
        steps["error"] = "GLM_API_KEY 未设置（运行 Flask 的这个进程读不到）。请在启动 app 的同一个 shell 里 set/export GLM_API_KEY 后重启。"
        return jsonify({"ok": False, **steps}), 200

    full_prompt = " ".join(core.split()) + _IMAGE_STYLE_SUFFIX_ZHIPU
    steps["full_prompt"] = full_prompt

    tmp_url = _zhipu_raw_image_temp_url(full_prompt)
    steps["zhipu_returned_url"] = bool(tmp_url)
    if tmp_url:
        steps["zhipu_temp_url_head"] = tmp_url[:120]
    if not tmp_url:
        steps["error"] = "智谱未返回图片 URL：多半是 Key 无效/欠费/被限流，或网络到 open.bigmodel.cn 不通。看 Flask 控制台里 'zhipu image ...' 的报错行。"
        return jsonify({"ok": False, **steps}), 200

    raw = _http_download_bytes(tmp_url)
    steps["downloaded_bytes"] = len(raw) if raw else 0
    if not raw:
        steps["error"] = "拿到智谱临时 URL 但下载图片失败（临时 URL 可能过期或网络不通）。"
        return jsonify({"ok": False, **steps}), 200

    png = _png_bytes_240_square(raw, label)
    steps["png_240_bytes"] = len(png) if png else 0
    if not png:
        steps["error"] = "240×240 裁切失败：检查 Pillow 是否已安装（pip install Pillow）。"
        return jsonify({"ok": False, **steps}), 200

    public_url = _autism_square_image_url_cached(label, core)
    steps["public_url"] = public_url
    steps["cached_and_backed_up"] = bool(public_url)
    return jsonify({"ok": bool(public_url), **steps}), 200


def _strip_pending_autism_daily_plan_from_device_queues(device_ids: list[str]) -> None:
    """从星星命令队列中移除尚未下发的旧「日常计划表」会话，避免多次下发时堆积或乱序。

    须在持有 `_esp32_cmd_lock` 时调用。"""
    for did in device_ids:
        q = _esp32_cmd_queue.get(did)
        if not q:
            continue
        kept: deque = deque()
        while q:
            cmd = q.popleft()
            if cmd.get("action") != "autism_session":
                kept.append(cmd)
                continue
            raw = cmd.get("session_json")
            if not isinstance(raw, str):
                kept.append(cmd)
                continue
            try:
                sj = json.loads(raw[:32000])
            except Exception:
                sj = {}
            if isinstance(sj, dict) and sj.get("kind") == "daily_plan":
                continue
            kept.append(cmd)
        _esp32_cmd_queue[did] = kept


def _strip_pending_autism_training_start_from_device_queues(device_ids: list[str]) -> None:
    """移除尚未下发的旧「日常训练开始」会话，避免家长多次下发在队列与单包批量里堆积。

    须在持有 `_esp32_cmd_lock` 时调用。"""
    for did in device_ids:
        q = _esp32_cmd_queue.get(did)
        if not q:
            continue
        kept: deque = deque()
        while q:
            cmd = q.popleft()
            if cmd.get("action") != "autism_session":
                kept.append(cmd)
                continue
            raw = cmd.get("session_json")
            if not isinstance(raw, str):
                kept.append(cmd)
                continue
            try:
                sj = json.loads(raw[:32000])
            except Exception:
                sj = {}
            if isinstance(sj, dict) and sj.get("kind") == "training_start":
                continue
            kept.append(cmd)
        _esp32_cmd_queue[did] = kept


def _autism_inject_scripted_audio(session: dict) -> None:
    """为脚本化语音（开场白 / 鼓励语 / 打分总结）预生成确定性本地 OGG，写进下发 JSON。

    设备拿到 intro_audio / praise_audio 后用 PlaySound 直接外放，不再走
    listen/detect + opening-hint 匹配的聊天链路——那条链路依赖时序与精确字符串
    匹配，麦克风一旦提前 VAD 触发就会变成 LLM 回应，孩子听不到该说的那句话。"""
    sk = session.get("kind")
    if sk == "training_start":
        intro = str(session.get("tts_intro") or "").strip() or "我们一起来做一个练习吧"
        url = _autism_tts_ogg_url(intro)
        if url:
            session["intro_audio"] = url
        options = session.get("options") if isinstance(session.get("options"), list) else []
        praise: dict[str, str] = {}
        for i, opt in enumerate(options[:4]):
            opt = str(opt or "").strip()
            if not opt:
                continue
            purl = _autism_tts_ogg_url(f"真棒！你选了{opt}，做得很好！")
            if purl:
                praise[f"o{i}"] = purl
        if praise:
            session["praise_audio"] = praise
    elif sk == "training_score":
        score = str(session.get("tts_intro") or "").strip()
        url = _autism_tts_ogg_url(score) if score else None
        if url:
            session["intro_audio"] = url
    elif sk == "daily_plan":
        slots = session.get("slots") if isinstance(session.get("slots"), list) else []
        intro_audio: dict[str, str] = {}
        for i, slot in enumerate(slots):
            if not isinstance(slot, dict):
                continue
            tts = str(slot.get("tts") or "").strip()
            if not tts:
                continue
            url = _autism_tts_ogg_url(tts)
            if url:
                intro_audio[f"s{i}"] = url
        if intro_audio:
            session["intro_audio"] = intro_audio


def _enqueue_autism_session_for_child(child_id: int, session: dict) -> list[str]:
    """把孤独症训练/日程 JSON 推入星星机器人长轮询命令队列。"""
    sk = session.get("kind")
    t0 = time.perf_counter()
    _autism_inject_scripted_audio(session)
    inject_ms = (time.perf_counter() - t0) * 1000.0
    app.logger.info(
        "autism_session inject_scripted_audio kind=%s took_ms=%.0f (edge-tts/ffmpeg 慢时家长会感觉「下发卡住」)",
        sk,
        inject_ms,
    )
    body = json.dumps(session, ensure_ascii=False)
    if len(body) > 32000:
        body = body[:32000]
    ids = _xingxing_device_ids_for_child(child_id)
    cmd_obj = {"action": "autism_session", "session_json": body}
    with _esp32_cmd_lock:
        if sk == "daily_plan":
            _strip_pending_autism_daily_plan_from_device_queues(ids)
        elif sk == "training_start":
            _strip_pending_autism_training_start_from_device_queues(ids)
        for did in ids:
            q = _esp32_cmd_queue.setdefault(did, deque())
            q.append(dict(cmd_obj))
        _esp32_cmd_lock.notify_all()
    return ids


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
    "autism_session",
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
    if action == "autism_session":
        sj = payload.get("session_json")
        if not isinstance(sj, str) or not sj.strip():
            return False, "session_json must be a non-empty string"
        if len(sj) > 64000:
            return False, "session_json too long (max 64000)"
        payload["session_json"] = sj.strip()
    return True, ""


def _device_bind_admin_secret() -> str:
    return (
        (os.getenv("DEVICE_BIND_ADMIN_TOKEN") or "").strip()
        or (os.getenv("ESP32_BIND_ADMIN_TOKEN") or "").strip()
        or (os.getenv("WEEKLY_REPORT_SECRET") or "").strip()
    )


def _device_bind_admin_authorized() -> bool:
    secret = _device_bind_admin_secret()
    if not secret:
        return False
    supplied = (
        (request.args.get("token") or "").strip()
        or (request.form.get("token") or "").strip()
        or (request.headers.get("X-Device-Bind-Admin-Token") or "").strip()
    )
    return hmac.compare_digest(supplied, secret)


def _device_kind_label(kind: str | None) -> str:
    role = _esp32_device_role(kind)
    if role == "plush":
        return "毛绒球"
    if role == "adhd_star":
        return "多动症星星机器人"
    if role == "autism_star":
        return "孤独症星星机器人"
    return "未标记设备"


def _device_bind_admin_redirect(message: str):
    token = (request.form.get("token") or request.args.get("token") or "").strip()
    msg = quote(message, safe="")
    if token:
        return redirect(f"/admin/device-bindings?token={quote(token, safe='')}&msg={msg}")
    return redirect(f"/admin/device-bindings?msg={msg}")


@app.route("/admin/device-bindings", methods=["GET", "POST"])
def admin_device_bindings():
    """管理三类 ESP32 设备与孩子的绑定关系。"""
    if not _device_bind_admin_secret():
        return Response(
            "DEVICE_BIND_ADMIN_TOKEN is not configured. "
            "Set it in the server environment before using this admin page.",
            status=503,
            mimetype="text/plain; charset=utf-8",
        )
    if not _device_bind_admin_authorized():
        return Response(
            "Unauthorized. Open /admin/device-bindings?token=<DEVICE_BIND_ADMIN_TOKEN>.",
            status=401,
            mimetype="text/plain; charset=utf-8",
        )

    conn = sqlite3.connect("adhd_data.db")
    cursor = conn.cursor()

    if request.method == "POST":
        action = (request.form.get("action") or "").strip()
        device_id = _normalize_device_id(request.form.get("device_id") or "")
        if not _ESP32_DEVICE_ID_RE.match(device_id):
            conn.close()
            return _device_bind_admin_redirect("设备 ID 无效")
        now = _now_str()
        if action == "unbind":
            cursor.execute(
                """
                UPDATE esp32_devices
                SET child_id = NULL, bound_by_user_id = NULL, last_seen_at = ?
                WHERE device_id = ?
                """,
                (now, device_id),
            )
            conn.commit()
            conn.close()
            return _device_bind_admin_redirect(f"已解绑 {device_id}")
        if action in ("bind", "create_bind"):
            try:
                child_id = int(request.form.get("child_id") or 0)
            except (TypeError, ValueError):
                conn.close()
                return _device_bind_admin_redirect("孩子 ID 无效")
            cursor.execute("SELECT id FROM children WHERE id = ?", (child_id,))
            if cursor.fetchone() is None:
                conn.close()
                return _device_bind_admin_redirect("孩子不存在")
            kind = (request.form.get("kind") or "").strip() or None
            cursor.execute(
                "SELECT user_id FROM child_members WHERE child_id = ? ORDER BY id ASC LIMIT 1",
                (child_id,),
            )
            member = cursor.fetchone()
            bound_by_user_id = member[0] if member else None
            cursor.execute("SELECT id FROM esp32_devices WHERE device_id = ?", (device_id,))
            row = cursor.fetchone()
            if row is None:
                cursor.execute(
                    """
                    INSERT INTO esp32_devices
                        (device_id, kind, child_id, bound_by_user_id, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (device_id, kind, child_id, bound_by_user_id, now, now),
                )
            else:
                cursor.execute(
                    """
                    UPDATE esp32_devices
                    SET kind = COALESCE(?, kind),
                        child_id = ?,
                        bound_by_user_id = ?,
                        last_seen_at = ?
                    WHERE device_id = ?
                    """,
                    (kind, child_id, bound_by_user_id, now, device_id),
                )
            conn.commit()
            conn.close()
            return _device_bind_admin_redirect(f"已绑定 {device_id} 到孩子 {child_id}")
        conn.close()
        return _device_bind_admin_redirect("未知操作")

    cursor.execute(
        """
        SELECT c.id, c.nickname,
               GROUP_CONCAT(COALESCE(u.display_name, u.username), ', ')
        FROM children c
        LEFT JOIN child_members m ON m.child_id = c.id
        LEFT JOIN users u ON u.id = m.user_id
        GROUP BY c.id, c.nickname
        ORDER BY c.id ASC
        """
    )
    children = cursor.fetchall()
    cursor.execute(
        """
        SELECT e.device_id, e.kind, e.child_id, c.nickname,
               e.bound_by_user_id, COALESCE(u.display_name, u.username),
               e.first_seen_at, e.last_seen_at
        FROM esp32_devices e
        LEFT JOIN children c ON c.id = e.child_id
        LEFT JOIN users u ON u.id = e.bound_by_user_id
        ORDER BY e.last_seen_at DESC
        """
    )
    devices = cursor.fetchall()
    conn.close()

    token = html.escape((request.args.get("token") or "").strip(), quote=True)
    msg = html.escape((request.args.get("msg") or "").strip())

    def child_options(selected=None) -> str:
        out = []
        for cid, nick, members in children:
            label = f"{cid} - {nick or '未命名孩子'}"
            if members:
                label += f"（{members}）"
            sel = " selected" if selected is not None and int(selected) == int(cid) else ""
            out.append(f'<option value="{cid}"{sel}>{html.escape(label)}</option>')
        return "".join(out)

    kind_options = [
        ("esp32-s3-lcd-1.47B", "毛绒球（ESP32-S3-LCD-1.47B 目录）"),
        ("xiaozhi-esp32-2.2.4", "多动症星星机器人（xiaozhi-esp32-2.2.4 目录）"),
        ("xingxing", "孤独症星星机器人（xingxing 目录）"),
        ("", "保持原 kind / 未标记"),
    ]

    def kind_select(current: str | None) -> str:
        cur = (current or "").strip()
        role = _esp32_device_role(cur)
        if role == "plush":
            selected_value = "esp32-s3-lcd-1.47B"
        elif role == "adhd_star":
            selected_value = "xiaozhi-esp32-2.2.4"
        elif role == "autism_star":
            selected_value = "xingxing"
        else:
            selected_value = cur
        opts = []
        for val, label in kind_options:
            sel = " selected" if val == selected_value else ""
            opts.append(
                f'<option value="{html.escape(val, quote=True)}"{sel}>{html.escape(label)}</option>'
            )
        return "".join(opts)

    rows = []
    for device_id, kind, child_id, child_nick, bound_uid, bound_user, first_seen, last_seen in devices:
        did = html.escape(device_id or "", quote=True)
        kind_raw = html.escape(kind or "")
        kind_label = html.escape(_device_kind_label(kind))
        child_text = "未绑定" if child_id is None else f"{child_id} - {child_nick or '未命名孩子'}"
        child_text = html.escape(child_text)
        bound_user_text = html.escape(bound_user or "")
        rows.append(
            f"""
            <tr>
              <td><code>{did}</code></td>
              <td>{kind_label}<br><small>{kind_raw}</small></td>
              <td>{child_text}<br><small>{bound_user_text}</small></td>
              <td><small>first: {html.escape(first_seen or '')}<br>last: {html.escape(last_seen or '')}</small></td>
              <td>
                <form method="post" class="inline">
                  <input type="hidden" name="token" value="{token}">
                  <input type="hidden" name="action" value="bind">
                  <input type="hidden" name="device_id" value="{did}">
                  <select name="child_id">{child_options(child_id)}</select>
                  <select name="kind">{kind_select(kind)}</select>
                  <button type="submit">绑定/改绑</button>
                </form>
                <form method="post" class="inline">
                  <input type="hidden" name="token" value="{token}">
                  <input type="hidden" name="action" value="unbind">
                  <input type="hidden" name="device_id" value="{did}">
                  <button type="submit" class="danger">解绑</button>
                </form>
              </td>
            </tr>
            """
        )

    body = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>设备绑定管理</title>
  <style>
    body {{ font-family: system-ui, -apple-system, Segoe UI, sans-serif; margin: 24px; background:#f7f7f8; color:#1f2937; }}
    h1 {{ margin-bottom: 8px; }}
    .card {{ background:white; border:1px solid #e5e7eb; border-radius:12px; padding:16px; margin:16px 0; box-shadow:0 1px 2px rgba(0,0,0,.04); }}
    table {{ width:100%; border-collapse:collapse; background:white; }}
    th, td {{ border-bottom:1px solid #e5e7eb; padding:10px; text-align:left; vertical-align:top; }}
    th {{ background:#f3f4f6; }}
    select, input {{ padding:6px; margin:3px 4px 3px 0; }}
    button {{ padding:6px 10px; border:0; border-radius:7px; background:#2563eb; color:white; cursor:pointer; }}
    button.danger {{ background:#dc2626; }}
    form.inline {{ display:inline-block; margin:2px 6px 2px 0; }}
    .msg {{ background:#ecfdf5; border:1px solid #a7f3d0; padding:10px; border-radius:8px; }}
    small {{ color:#6b7280; }}
    code {{ font-weight:700; }}
  </style>
</head>
<body>
  <h1>设备绑定管理</h1>
  <p>管理三类 ESP32 设备与孩子之间的绑定关系：毛绒球、多动症星星机器人、孤独症星星机器人。</p>
  {f'<div class="msg">{msg}</div>' if msg else ''}
  <div class="card">
    <h2>手动添加/绑定设备</h2>
    <form method="post">
      <input type="hidden" name="token" value="{token}">
      <input type="hidden" name="action" value="create_bind">
      <input name="device_id" placeholder="例如 8FDAD94C" required>
      <select name="child_id">{child_options()}</select>
      <select name="kind">{kind_select('esp32-s3-lcd-1.47B')}</select>
      <button type="submit">创建并绑定</button>
    </form>
  </div>
  <div class="card">
    <h2>当前设备</h2>
    <table>
      <thead><tr><th>Device ID</th><th>类型</th><th>绑定孩子</th><th>在线时间</th><th>操作</th></tr></thead>
      <tbody>{''.join(rows) or '<tr><td colspan="5">暂无设备</td></tr>'}</tbody>
    </table>
  </div>
</body>
</html>"""
    return Response(body, mimetype="text/html; charset=utf-8")


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


@app.route("/device/<device_id>/xiaozhi/opening-hint", methods=["POST"])
def esp32_xiaozhi_opening_hint(device_id: str):
    """设备本地定时事件触发前，预置 xiaozhi 主动开场 hint。

    计划表到点由 ESP32 本地调度触发，服务器没有机会提前 stash opening。
    设备先 POST 这条 hint，再发送 listen/detect 文本，xiaozhi_bridge 就会只播
    opening，不会把这句主动问题当成孩子输入交给 Kimi。
    """
    device_id = _normalize_device_id(device_id)
    if not _ESP32_DEVICE_ID_RE.match(device_id):
        return jsonify({"status": "error", "message": "invalid device_id"}), 400
    data = request.json or {}
    opening = str(data.get("opening_line") or "").strip()
    if not opening:
        return jsonify({"status": "error", "message": "opening_line required"}), 400
    opening = (
        opening.replace("\\", "").replace('"', "").replace("\r", " ").replace("\n", " ")
    )[:500]
    while "  " in opening:
        opening = opening.replace("  ", " ")
    context = str(data.get("context") or "").strip()[:8000]
    try:
        from xiaozhi_bridge import stash_xinvoke_hint

        stash_xinvoke_hint(device_id, opening, context)
    except Exception as e:
        app.logger.warning("xiaozhi opening-hint stash failed: %s", e)
        return jsonify({"status": "error", "message": "stash failed"}), 500
    app.logger.info("xiaozhi opening-hint stashed device=%s len=%d", device_id, len(opening))
    return jsonify({"status": "ok"}), 200


if __name__ == '__main__':
    # 周/月/年报告改为家长主动生成，避免孩子多时后台批量产生大量报告数据。
    # 绑定 0.0.0.0 确保外网可访问，端口使用你已开放的 11760
    app.run(host='0.0.0.0', port=11760, debug=False, threaded=True)
