# Path A: xiaozhi-esp32 WebSocket bridge (hello / listen / opus) + Kimi reply +
# edge-tts playback. OTA is intentionally NOT exposed here — devices must be
# pre-flashed with `CONFIG_ADHD_MONITOR_BYPASS_OTA=y` so they seed the
# `websocket` NVS namespace from Kconfig at boot and never call any OTA
# endpoint. ASR uses Baidu short-speech recognition (vop.baidu.com); set
# BAIDU_SPEECH_API_KEY / BAIDU_SPEECH_SECRET_KEY (no OpenAI required).

from __future__ import annotations

import asyncio
import json
import logging
import os
import struct
import tempfile
import time
import uuid

import requests
from openai import OpenAI

log = logging.getLogger(__name__)

# device_id (MAC hex, no colons, upper) -> (deadline_monotonic, {"opening": str, "context": str})
_xinvoke_hints: dict[str, tuple[float, dict[str, str]]] = {}


def _norm_dev_header(mac: str) -> str:
    """归一化 Device-Id 头到与 `esp32_devices.device_id` / `_esp32_cmd_queue` 一致的 8-hex 形式。

    - 固件通过 WebSocket 上送 `Device-Id: 98:88:e0:16:05:60` 这种完整 STA MAC；
      `app.py:_normalize_device_id` 只去掉冒号，保留 12 个字符（"9888E0160560"）。
    - 但 `_enqueue_xiaozhi_for_child` 调 `stash_xinvoke_hint(did, …)` 时拿到的
      `did` 来自 `esp32_devices.device_id`，那里的值是固件 announce 时上送的
      `PathADeviceIdUpper()` —— MAC 最后 4 字节的 8-hex（"E0160560"）。
    - 不归一化的话，stash key 是 "E0160560"、pop 用 "9888E0160560" 永远取不到，
      家长一记录观察就算云端把 hint 推下来，xiaozhi WebSocket 这边也是空 context，
      Kimi 只会念一句通用问候——这就是为什么"家长记录后机器人没说出具体行为"。
    - 统一截到最后 8 个 hex 后，HTTP 长轮询通道（8-hex）和 WS 通道（截尾 8-hex）
      会落到同一个 key 上。
    """
    s = (mac or "").replace(":", "").replace("-", "").strip().upper()
    if len(s) >= 8:
        return s[-8:]
    return s


def stash_xinvoke_hint(device_id: str, opening_line: str, context: str) -> None:
    did = _norm_dev_header(device_id)
    if not did:
        return
    _xinvoke_hints[did] = (
        time.monotonic() + 180.0,
        {
            "opening": (opening_line or "")[:500],
            "context": (context or "")[:8000],
        },
    )


def pop_xinvoke_hint(device_id: str) -> dict[str, str]:
    did = _norm_dev_header(device_id)
    now = time.monotonic()
    ent = _xinvoke_hints.pop(did, None)
    if ent is None or ent[0] < now:
        return {"opening": "", "context": ""}
    return ent[1]


def _expected_token() -> str:
    return (os.getenv("XIAOZHI_WEBSOCKET_TOKEN") or "").strip()


def _unpack_uplink_audio_v2_v3(protocol_version: int, data: bytes) -> bytes | None:
    if protocol_version <= 1:
        return data
    if protocol_version == 2 and len(data) >= 16:
        _ver, typ, _res, _ts, psz = struct.unpack(">HHIII", data[:16])
        if typ != 0:
            return None
        end = 16 + psz
        if len(data) < end:
            return None
        return data[16:end]
    if protocol_version == 3 and len(data) >= 4:
        typ = data[0]
        psz = struct.unpack(">H", data[2:4])[0]
        if typ != 0:
            return None
        end = 4 + psz
        if len(data) < end:
            return None
        return data[4:end]
    return data


def _moonshot_client() -> OpenAI:
    return OpenAI(
        api_key=os.getenv("MOONSHOT_API_KEY", ""),
        base_url=os.getenv("MOONSHOT_BASE_URL", "https://api.moonshot.cn/v1"),
    )


def _kimi_reply(system: str, user_text: str) -> str:
    key = os.getenv("MOONSHOT_API_KEY", "")
    if not key or key.startswith("你的_"):
        return "请先在服务器配置 MOONSHOT_API_KEY。"
    client = _moonshot_client()
    model = os.getenv("XIAOZHI_CHAT_MODEL", "moonshot-v1-8k")
    r = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user_text},
        ],
        temperature=0.6,
        max_tokens=512,
    )
    return (r.choices[0].message.content or "").strip()


# ── 百度短语音识别（替代 OpenAI Whisper）─────────────────────────────────
# 文档：https://cloud.baidu.com/doc/SPEECH/s/Jlbxdezuf
#   1) 用 API Key + Secret Key 走 OAuth 2.0 client_credentials 拿 access_token
#      （有效期 ~30 天，本地缓存，避免每轮调用都换 token）
#   2) 走 RAW 上传：POST http://vop.baidu.com/server_api?cuid=...&token=...&dev_pid=1537
#      Content-Type: audio/pcm;rate=16000 ，body 为 16k/16bit/单声道 PCM。
#      （JSON+base64 上传也可，但要多 1/3 体积。）
#   3) 返回 JSON： err_no=0 时 result[0] 即识别文本。

_baidu_token_cache: dict[str, float | str] = {"value": "", "expire_at": 0.0}


def _baidu_get_access_token() -> str:
    api_key = (os.getenv("BAIDU_SPEECH_API_KEY") or "").strip()
    secret_key = (os.getenv("BAIDU_SPEECH_SECRET_KEY") or "").strip()
    if not api_key or not secret_key:
        return ""
    now = time.monotonic()
    cached = _baidu_token_cache.get("value") or ""
    expire_at = float(_baidu_token_cache.get("expire_at") or 0.0)
    if cached and now < expire_at:
        return str(cached)
    try:
        r = requests.post(
            "https://aip.baidubce.com/oauth/2.0/token",
            params={
                "grant_type": "client_credentials",
                "client_id": api_key,
                "client_secret": secret_key,
            },
            timeout=10,
        )
    except Exception as e:
        log.warning("baidu oauth failed: %s", e)
        return ""
    if r.status_code != 200:
        log.warning("baidu oauth http %s: %s", r.status_code, r.text[:400])
        return ""
    data = r.json() if r.content else {}
    token = (data.get("access_token") or "").strip()
    expires_in = int(data.get("expires_in") or 0)
    if not token:
        log.warning("baidu oauth no token: %s", data)
        return ""
    # 提前 10 分钟续期，避免拿到刚过期的 token
    _baidu_token_cache["value"] = token
    _baidu_token_cache["expire_at"] = now + max(expires_in - 600, 300)
    return token


def _baidu_cuid() -> str:
    cuid = (os.getenv("BAIDU_SPEECH_CUID") or "").strip()
    return cuid or "adhd-monitor-server"


def _baidu_dev_pid() -> int:
    """1537=普通话(默认)，1737=英语，1637=粤语，1837=四川话。"""
    raw = (os.getenv("BAIDU_SPEECH_DEV_PID") or "").strip()
    try:
        return int(raw) if raw else 1537
    except ValueError:
        return 1537


def _transcribe_pcm(pcm_bytes: bytes, sample_rate: int = 16000) -> str:
    """把 16k/16bit/单声道 PCM 上送百度短语音识别，返回中文文本（失败返回 ''）。"""
    if not pcm_bytes:
        return ""
    if sample_rate not in (8000, 16000):
        log.warning("baidu asr unsupported sample_rate=%d, fallback to 16000", sample_rate)
        sample_rate = 16000
    # 百度短语音上限 ~60s；16k/16bit/单声道 = 32000 B/s，~1.92 MB
    max_bytes = sample_rate * 2 * 60
    if len(pcm_bytes) > max_bytes:
        log.warning(
            "baidu asr clip overlength %d>%d bytes, truncating",
            len(pcm_bytes),
            max_bytes,
        )
        pcm_bytes = pcm_bytes[:max_bytes]
    token = _baidu_get_access_token()
    if not token:
        return ""
    try:
        r = requests.post(
            "https://vop.baidu.com/server_api",
            params={
                "cuid": _baidu_cuid(),
                "token": token,
                "dev_pid": _baidu_dev_pid(),
            },
            headers={"Content-Type": f"audio/pcm;rate={sample_rate}"},
            data=pcm_bytes,
            timeout=30,
        )
    except Exception as e:
        log.warning("baidu asr request failed: %s", e)
        return ""
    if r.status_code != 200:
        log.warning("baidu asr http %s: %s", r.status_code, r.text[:400])
        return ""
    try:
        data = r.json()
    except ValueError:
        log.warning("baidu asr non-json: %s", r.text[:400])
        return ""
    if int(data.get("err_no", -1)) != 0:
        log.warning("baidu asr err_no=%s err_msg=%s", data.get("err_no"), data.get("err_msg"))
        return ""
    result = data.get("result") or []
    if not isinstance(result, list) or not result:
        return ""
    return str(result[0]).strip()


def _opus_to_pcm(opus_packets: list[bytes], sample_rate: int = 16000) -> bytes:
    """解码所有上行 opus 帧 → 16k/16bit/单声道 PCM 字节流，供百度 ASR 直接 RAW 上送。"""
    if not opus_packets:
        return b""
    try:
        dec = __import__("opuslib").Decoder(sample_rate, 1)
    except Exception as e:
        log.error("opuslib decoder: %s", e)
        return b""
    pcm = bytearray()
    frame_samples = int(sample_rate * 60 / 1000)  # 设备默认 60ms 帧
    for pkt in opus_packets:
        try:
            chunk = dec.decode(bytes(pkt), frame_samples)
            pcm.extend(chunk)
        except Exception as ex:
            log.debug("opus frame skip: %s", ex)
    return bytes(pcm)


def _tts_to_opus_packets(text: str, out_sr: int = 24000) -> list[bytes]:
    """edge-tts -> mp3 -> ffmpeg PCM -> opuslib packets (60ms)."""
    import shutil
    import subprocess

    import edge_tts

    if shutil.which("ffmpeg") is None:
        log.error("ffmpeg not found; cannot build TTS opus")
        return []
    fd_mp3, mp3 = tempfile.mkstemp(suffix=".mp3")
    fd_pcm, pcm_path = tempfile.mkstemp(suffix=".pcm")
    import os as _os

    _os.close(fd_mp3)
    _os.close(fd_pcm)
    try:

        async def _run() -> None:
            comm = edge_tts.Communicate(
                text, os.getenv("XIAOZHI_TTS_VOICE", "zh-CN-XiaoxiaoNeural")
            )
            await comm.save(mp3)

        asyncio.run(_run())
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i",
                mp3,
                "-f",
                "s16le",
                "-ac",
                "1",
                "-ar",
                str(out_sr),
                pcm_path,
            ],
            check=True,
            capture_output=True,
        )
        raw = open(pcm_path, "rb").read()
        if not raw:
            return []
        enc = __import__("opuslib").Encoder(
            out_sr, 1, __import__("opuslib").APPLICATION_VOIP
        )
        samples_per_frame = int(out_sr * 60 / 1000)
        bytes_per_frame = samples_per_frame * 2
        packets: list[bytes] = []
        for i in range(0, len(raw), bytes_per_frame):
            frame = raw[i : i + bytes_per_frame]
            if len(frame) < bytes_per_frame:
                frame = frame + b"\x00" * (bytes_per_frame - len(frame))
            packets.append(enc.encode(frame, samples_per_frame))
        return packets
    except Exception as e:
        log.exception("tts pipeline: %s", e)
        return []
    finally:
        for p in (mp3, pcm_path):
            try:
                _os.remove(p)
            except OSError:
                pass


class XiaozhiConn:
    def __init__(self, ws) -> None:
        self.ws = ws
        self.session_id = str(uuid.uuid4())
        self.proto_version = 1
        self.uplink_packets: list[bytes] = []
        self.device_mac = ""
        self._session_ended = False
        self.hint_opening = ""
        self.hint_context = ""

    def send_json(self, obj: dict) -> None:
        self.ws.send(json.dumps(obj, ensure_ascii=False))

    def run(self) -> None:
        try:
            from flask import request

            self.device_mac = request.headers.get("Device-Id", "")
        except Exception:
            self.device_mac = ""
        hint = pop_xinvoke_hint(self.device_mac)
        self.hint_opening = hint.get("opening") or ""
        self.hint_context = hint.get("context") or ""

        while True:
            try:
                msg = self.ws.receive()
            except Exception:
                break
            if msg is None:
                break
            if isinstance(msg, (bytes, bytearray)):
                pkt = _unpack_uplink_audio_v2_v3(self.proto_version, bytes(msg))
                if pkt:
                    self.uplink_packets.append(pkt)
                continue
            try:
                root = json.loads(msg)
            except json.JSONDecodeError:
                continue
            mtype = root.get("type")
            if mtype == "hello":
                self._on_client_hello(root)
            elif mtype == "listen":
                st = root.get("state")
                if st == "start":
                    self.uplink_packets = []
                    self._session_ended = False
                elif st in ("stop", "end"):
                    self._on_listen_stop()
                elif st == "detect":
                    t = root.get("text") or ""
                    if isinstance(t, str) and t.strip():
                        self.uplink_packets = []
                        self._reply_turn(t.strip())
            elif mtype == "abort":
                self.uplink_packets = []
            elif mtype == "mcp":
                pass
            else:
                log.debug("ignored json type=%s", mtype)

    def _on_client_hello(self, root: dict) -> None:
        self.proto_version = int(root.get("version") or 1)
        self.send_json(
            {
                "type": "hello",
                "transport": "websocket",
                "session_id": self.session_id,
                "audio_params": {
                    "format": "opus",
                    "sample_rate": 24000,
                    "channels": 1,
                    "frame_duration": 60,
                },
            }
        )

    def _on_listen_stop(self) -> None:
        if self._session_ended:
            self.uplink_packets = []
            return
        pcm = _opus_to_pcm(self.uplink_packets, 16000)
        user_text = _transcribe_pcm(pcm, 16000) if pcm else ""
        if not user_text:
            user_text = (
                "（没有听清你说的话；请检查服务器 BAIDU_SPEECH_API_KEY / "
                "BAIDU_SPEECH_SECRET_KEY 是否配置正确。）"
            )
        self._reply_turn(user_text)

    def _reply_turn(self, user_text: str) -> None:
        if self._session_ended:
            return
        self._session_ended = True

        # ── 主动开场：家长记录行为 → app.py:_enqueue_xiaozhi_for_child 把 Kimi
        # 生成的 child_script 塞进 hint["opening"]，然后通过 _esp32_cmd_queue
        # 推 `xiaozhi_invoke_chat`，固件长轮询拿到后调 WakeWordInvoke(child_script)，
        # 走到 SendWakeWordDetected → 服务器这边收到 `listen state=detect text=<child_script>`。
        # 此时 user_text 就等于 hint_opening：不能再当作"孩子说的话"喂给 Kimi，
        # 否则会出现机器人回应自己刚说出口的开场白这种诡异行为。
        # 直接把 child_script 当对孩子说的话 TTS 播一遍即可——这条线就是
        # "Flutter 上报行为 → 云端 Kimi 写出针对该行为的开场白 → 百度 / edge-tts
        # 合成音 → 星星机器人对孩子说"那条链路最后落地的一步。
        is_proactive_opening = (
            bool(self.hint_opening)
            and user_text.strip() == self.hint_opening.strip()
        )
        if is_proactive_opening:
            reply = self.hint_opening
            log.info(
                "xiaozhi proactive opening (parent-triggered), len=%d", len(reply)
            )
        else:
            sys_prompt = (
                "你是陪伴孩子成长的口语伙伴，语气温暖简短，适合外放给孩子听。"
                "回答控制在 2～4 句中文。"
            )
            if self.hint_context:
                sys_prompt += (
                    "\n以下是家长端上下文（可能含医疗/教育观察，仅供参考）：\n"
                    + self.hint_context
                )
            reply = _kimi_reply(sys_prompt, user_text)
            if self.hint_opening and len(reply) < 400:
                reply = self.hint_opening + reply

        self.send_json(
            {"session_id": self.session_id, "type": "stt", "text": user_text}
        )
        self.send_json(
            {"session_id": self.session_id, "type": "tts", "state": "start"}
        )
        self.send_json(
            {
                "session_id": self.session_id,
                "type": "tts",
                "state": "sentence_start",
                "text": reply[:200],
            }
        )
        for pkt in _tts_to_opus_packets(reply, 24000):
            self.ws.send(pkt)
        self.send_json(
            {"session_id": self.session_id, "type": "tts", "state": "stop"}
        )
        try:
            self.ws.close()
        except Exception:
            pass


def register_xiaozhi(app, sock) -> None:
    """Mount only the WebSocket endpoint on the shared Flask app + flask-sock."""
    from flask import request

    @sock.route("/xiaozhi/ws")
    def xiaozhi_ws(ws):
        expected = _expected_token()
        if expected:
            sent = (request.headers.get("Authorization") or "").strip()
            if sent.startswith("Bearer "):
                sent = sent[len("Bearer ") :].strip()
            if sent != expected:
                log.warning(
                    "xiaozhi ws rejected: token mismatch from device %s",
                    request.headers.get("Device-Id", "?"),
                )
                try:
                    ws.close()
                except Exception:
                    pass
                return
        try:
            XiaozhiConn(ws).run()
        except Exception:
            log.exception("xiaozhi_ws session error")
