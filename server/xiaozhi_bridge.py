# Path A: xiaozhi-esp32 WebSocket bridge (hello / listen / opus) + Kimi reply +
# edge-tts playback. OTA is intentionally NOT exposed here — devices must be
# pre-flashed with `CONFIG_ADHD_MONITOR_BYPASS_OTA=y` so they seed the
# `websocket` NVS namespace from Kconfig at boot and never call any OTA
# endpoint. Optional ASR: OpenAI Whisper (set OPENAI_API_KEY).

from __future__ import annotations

import asyncio
import json
import logging
import os
import struct
import tempfile
import time
import uuid
import wave

import requests
from openai import OpenAI

log = logging.getLogger(__name__)

# device_id (MAC hex, no colons, upper) -> (deadline_monotonic, {"opening": str, "context": str})
_xinvoke_hints: dict[str, tuple[float, dict[str, str]]] = {}


def _norm_dev_header(mac: str) -> str:
    return (mac or "").replace(":", "").replace("-", "").strip().upper()


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


def _transcribe_wav(wav_path: str) -> str:
    key = (os.getenv("OPENAI_API_KEY") or "").strip()
    if not key:
        return ""
    try:
        with open(wav_path, "rb") as f:
            r = requests.post(
                "https://api.openai.com/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {key}"},
                files={"file": ("audio.wav", f, "audio/wav")},
                data={"model": "whisper-1"},
                timeout=120,
            )
        if r.status_code != 200:
            log.warning("whisper http %s: %s", r.status_code, r.text[:500])
            return ""
        data = r.json()
        return (data.get("text") or "").strip()
    except Exception as e:
        log.warning("whisper failed: %s", e)
        return ""


def _opus_to_wav(opus_packets: list[bytes], sample_rate: int = 16000) -> str | None:
    if not opus_packets:
        return None
    try:
        dec = __import__("opuslib").Decoder(sample_rate, 1)
    except Exception as e:
        log.error("opuslib decoder: %s", e)
        return None
    pcm = bytearray()
    frame_samples = int(sample_rate * 60 / 1000)  # 60ms frames
    for pkt in opus_packets:
        try:
            chunk = dec.decode(bytes(pkt), frame_samples)
            pcm.extend(chunk)
        except Exception as ex:
            log.debug("opus frame skip: %s", ex)
    if not pcm:
        return None
    fd, path = tempfile.mkstemp(suffix=".wav")
    import os as _os

    _os.close(fd)
    try:
        with wave.open(path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(bytes(pcm))
        return path
    except Exception:
        return None


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
        user_text = ""
        wav = _opus_to_wav(self.uplink_packets, 16000)
        if wav:
            user_text = _transcribe_wav(wav)
            try:
                os.remove(wav)
            except OSError:
                pass
        if not user_text:
            user_text = (
                "（没有听清你说的话；若需语音识别请配置 OPENAI_API_KEY 以使用 Whisper。）"
            )
        self._reply_turn(user_text)

    def _reply_turn(self, user_text: str) -> None:
        if self._session_ended:
            return
        self._session_ended = True
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
