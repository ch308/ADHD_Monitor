#!/usr/bin/env python3
"""Generate firmware assets for the "action cards" feature.

The feature shows ten 240x240 pictures (one per daily routine action) embedded
in the firmware as RGB565 LVGL C arrays, plus five optional "choice hint" images
(欢迎你 / 请选择 / 你想做什么 / 击掌庆祝 / 你真棒) used by Path A autism UI.
After the child taps the picture to confirm, the device plays an offline
Ogg/Opus clip: the spoken sentence "妈妈，我要" plus the action label
(e.g. 起床), via AudioService::PlaySound().

This script produces four kinds of output:

  1. RGB565 LVGL C arrays   -> main/action_cards/images/<slug>.c
     (ten routine cards + five hint images when sources exist)
  2. Ogg/Opus voice clips    -> main/assets/locales/zh-CN/act_<slug>.ogg
     (TTS text: "妈妈，我要" + Chinese label; gen_lang.py -> Lang::Sounds::OGG_ACT_<SLUG>)
     When using --audio, also writes hint_welcome.ogg and hint_try_shake.ogg
     ("嗨，今天又是美好的一天" / "你试着摇摇我吧").
  3. A manifest header       -> main/action_cards/action_cards_generated.h
     (the table consumed by action_cards.cc; flips ACTION_CARDS_HAVE_AUDIO to 1
      only once every voice clip exists, so the project always builds)
  4. Hint image declarations -> main/action_cards/choice_hint_images_generated.h

Images need only Pillow + the project's LVGLImage.py (pypng + lz4). They are
produced in any environment. Voice generation needs an online TTS (edge-tts by
default) plus ffmpeg with libopus, matching the project's mp3_to_ogg.sh format
(libopus, mono, 16 kHz, 60 ms frames); run that part on your build machine.
edge-tts needs Python 3.8+ (e.g. ``python3.12`` on hosts where ``python3`` is 3.6).
Put ``ffmpeg`` on PATH (e.g. user static build under ``~/.local/bin``) if it is
not installed system-wide.

Usage:
  python3 scripts/gen_action_cards.py --images          # convert pictures only
  python3 scripts/gen_action_cards.py --audio           # synthesize voice only
  python3 scripts/gen_action_cards.py --images --audio  # everything
  (no flag defaults to --images, the part that always works offline-friendly)
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------------------
# The ten daily-routine actions, in the order the slideshow walks through them.
# (chinese_name, ascii_slug, source_png_filename)
# - chinese_name is spoken by TTS and shown as the label (no file extension).
# - ascii_slug becomes the ogg filename and the OGG_ symbol.
# - image_symbol() derives the C identifier used by LVGLImage.py.
# ---------------------------------------------------------------------------
ACTIONS = [
    ("起床",     "get_up",       "起床.png"),
    ("上洗手间", "go_toilet",    "上洗手间.png"),
    ("刷牙",     "brush_teeth",  "刷牙.png"),
    ("洗脸",     "wash_face",    "洗脸.png"),
    ("梳头",     "comb_hair",    "梳头.png"),
    ("穿衣服",   "wear_clothes", "穿衣服.png"),
    ("穿鞋子",   "wear_shoes",   "穿鞋子.png"),
    ("洗手",     "wash_hands",   "洗手.png"),
    ("洗澡",     "take_bath",    "洗澡.png"),
    ("睡觉",     "sleep",        "睡觉.png"),
]

# Extra 240x240 RGB565 images (no "妈妈，我要" voice, not in kActionCards).
# (ascii_slug_for_c_array, source_png_filename)
CHOICE_HINT_IMAGES = [
    ("welcome_ni", "欢迎你.png"),
    ("please_choose", "请选择.png"),
    ("what_you_want", "你想做什么.png"),
    ("celebrate_highfive", "击掌庆祝.png"),
    ("you_great", "你真棒.png"),
]

# Avoid names exported by libc/POSIX headers. LVGL image descriptors are linked as
# globals, so a card named "sleep" collides with unistd.h's sleep().
IMAGE_SYMBOL_OVERRIDES = {
    "sleep": "action_card_sleep",
}

# Paths are resolved relative to the repo (.../xingxing) which is the parent of
# this script's directory.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
LVGL_IMAGE_PY = os.path.join(SCRIPT_DIR, "Image_Converter", "LVGLImage.py")

# Source pictures live in the sibling assets/action directory of ADHD_Monitor.
ADHD_DIR = os.path.dirname(PROJECT_DIR)
SRC_IMAGE_DIR = os.path.join(ADHD_DIR, "assets", "action")

IMAGES_OUT_DIR = os.path.join(PROJECT_DIR, "main", "action_cards", "images")
MANIFEST_PATH = os.path.join(PROJECT_DIR, "main", "action_cards", "action_cards_generated.h")
CHOICE_HINT_HEADER = os.path.join(PROJECT_DIR, "main", "action_cards", "choice_hint_images_generated.h")
AUDIO_OUT_DIR = os.path.join(PROJECT_DIR, "main", "assets", "locales", "zh-CN")

IMAGE_SIZE = 240


def log(msg):
    print("[gen_action_cards] " + msg)


def image_symbol(slug):
    return IMAGE_SYMBOL_OVERRIDES.get(slug, slug)


def generate_images():
    """Convert each source PNG to a 240x240 RGB565 LVGL C array."""
    try:
        from PIL import Image
    except ImportError:
        raise SystemExit("Pillow is required for image conversion: pip install Pillow")
    if not os.path.isfile(LVGL_IMAGE_PY):
        raise SystemExit("LVGLImage.py not found at %s" % LVGL_IMAGE_PY)

    os.makedirs(IMAGES_OUT_DIR, exist_ok=True)
    expected_outputs = set("%s.c" % image_symbol(slug) for _cn, slug, _png in ACTIONS)
    expected_outputs.update("%s.c" % slug for slug, _png in CHOICE_HINT_IMAGES)
    for filename in os.listdir(IMAGES_OUT_DIR):
        if filename.endswith(".c") and filename not in expected_outputs:
            os.remove(os.path.join(IMAGES_OUT_DIR, filename))
    tmp_dir = tempfile.mkdtemp(prefix="action_cards_img_")
    try:
        def convert_one(png_name, slug):
            src = os.path.join(SRC_IMAGE_DIR, png_name)
            if not os.path.isfile(src):
                raise SystemExit("source picture missing: %s" % src)
            img = Image.open(src).convert("RGB")
            if img.size != (IMAGE_SIZE, IMAGE_SIZE):
                img = img.resize((IMAGE_SIZE, IMAGE_SIZE), Image.LANCZOS)
            symbol = image_symbol(slug)
            ascii_png = os.path.join(tmp_dir, symbol + ".png")
            img.save(ascii_png)
            cmd = [
                sys.executable, LVGL_IMAGE_PY,
                "--ofmt", "C",
                "--cf", "RGB565",
                "--compress", "NONE",
                "-o", IMAGES_OUT_DIR,
                ascii_png,
            ]
            log("converting %s -> images/%s.c" % (png_name, symbol))
            subprocess.check_call(cmd)

        for cn_name, slug, png_name in ACTIONS:
            convert_one(png_name, slug)
        for slug, png_name in CHOICE_HINT_IMAGES:
            convert_one(png_name, slug)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
    log("image conversion done (%d routine + %d hint files)"
        % (len(ACTIONS), len(CHOICE_HINT_IMAGES)))


def _which(prog):
    return shutil.which(prog)


def generate_audio():
    """Synthesize each Chinese name to an Ogg/Opus clip (online TTS + ffmpeg)."""
    ffmpeg = _which("ffmpeg")
    if not ffmpeg:
        raise SystemExit(
            "ffmpeg (with libopus) is required for audio. Install it and re-run, "
            "or run this --audio step on your build machine."
        )
    try:
        import edge_tts  # noqa: F401
        import asyncio
    except ImportError:
        raise SystemExit(
            "edge-tts is required for audio: pip install edge-tts (needs Python 3.8+, "
            "and network access to Microsoft's online TTS)."
        )
    import edge_tts

    os.makedirs(AUDIO_OUT_DIR, exist_ok=True)
    voice = os.environ.get("ACTION_TTS_VOICE", "zh-CN-XiaoxiaoNeural")
    tmp_dir = tempfile.mkdtemp(prefix="action_cards_aud_")

    async def synth(text, mp3_path):
        communicate = edge_tts.Communicate(text, voice)
        await communicate.save(mp3_path)

    try:
        for cn_name, slug, _png in ACTIONS:
            mp3_path = os.path.join(tmp_dir, slug + ".mp3")
            ogg_path = os.path.join(AUDIO_OUT_DIR, "act_%s.ogg" % slug)
            spoken = "妈妈，我要%s" % cn_name
            log("TTS '%s' -> %s" % (spoken, os.path.basename(ogg_path)))
            asyncio.run(synth(spoken, mp3_path))
            # Match the project's mp3_to_ogg.sh format exactly.
            subprocess.check_call([
                ffmpeg, "-y", "-i", mp3_path,
                "-c:a", "libopus", "-b:a", "16k", "-ac", "1",
                "-ar", "16000", "-frame_duration", "60",
                ogg_path,
            ])
        # Power-on welcome (embedded zh-CN); not part of the ten routine cards.
        mp3_welcome = os.path.join(tmp_dir, "hint_welcome.mp3")
        ogg_welcome = os.path.join(AUDIO_OUT_DIR, "hint_welcome.ogg")
        welcome_text = "\u55e8\uff0c\u4eca\u5929\u53c8\u662f\u7f8e\u597d\u7684\u4e00\u5929"  # 嗨，今天又是美好的一天
        log("TTS '%s' -> hint_welcome.ogg" % welcome_text)
        asyncio.run(synth(welcome_text, mp3_welcome))
        subprocess.check_call([
            ffmpeg, "-y", "-i", mp3_welcome,
            "-c:a", "libopus", "-b:a", "16k", "-ac", "1",
            "-ar", "16000", "-frame_duration", "60",
            ogg_welcome,
        ])
        mp3_shake = os.path.join(tmp_dir, "hint_try_shake.mp3")
        ogg_shake = os.path.join(AUDIO_OUT_DIR, "hint_try_shake.ogg")
        shake_text = "\u4f60\u8bd5\u7740\u6447\u6447\u6211\u5427"  # 你试着摇摇我吧
        log("TTS '%s' -> hint_try_shake.ogg" % shake_text)
        asyncio.run(synth(shake_text, mp3_shake))
        subprocess.check_call([
            ffmpeg, "-y", "-i", mp3_shake,
            "-c:a", "libopus", "-b:a", "16k", "-ac", "1",
            "-ar", "16000", "-frame_duration", "60",
            ogg_shake,
        ])
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
    log("audio generation done (%d routine + hint_welcome + hint_try_shake)" % len(ACTIONS))


def audio_present():
    """True only when every action already has its ogg clip on disk."""
    for _cn, slug, _png in ACTIONS:
        if not os.path.isfile(os.path.join(AUDIO_OUT_DIR, "act_%s.ogg" % slug)):
            return False
    return True


def write_manifest():
    """Emit the action_cards_generated.h table consumed by action_cards.cc."""
    os.makedirs(os.path.dirname(MANIFEST_PATH), exist_ok=True)
    have_audio = audio_present()

    lines = []
    lines.append("// Auto-generated by scripts/gen_action_cards.py - DO NOT EDIT.")
    lines.append("#pragma once")
    lines.append("")
    lines.append("#include <lvgl.h>")
    lines.append("#include <array>")
    lines.append("#include <string_view>")
    lines.append("")
    lines.append("// Flipped to 1 only when every act_<slug>.ogg voice clip exists,")
    lines.append("// so the firmware always builds even before audio is generated.")
    lines.append("#define ACTION_CARDS_HAVE_AUDIO %d" % (1 if have_audio else 0))
    lines.append("")
    lines.append("#if ACTION_CARDS_HAVE_AUDIO")
    lines.append('#include "assets/lang_config.h"')
    lines.append("#endif")
    lines.append("")
    for _cn, slug, _png in ACTIONS:
        lines.append("extern const lv_image_dsc_t %s;" % image_symbol(slug))
    lines.append("")
    lines.append("struct ActionCard {")
    lines.append("    const lv_image_dsc_t* image;  // 240x240 RGB565 picture")
    lines.append("    const char* name;             // Chinese name, no extension")
    lines.append("#if ACTION_CARDS_HAVE_AUDIO")
    lines.append("    std::string_view sound;       // offline Ogg: 妈妈，我要 + name")
    lines.append("#endif")
    lines.append("};")
    lines.append("")
    lines.append("static const std::array<ActionCard, %d> kActionCards = {{" % len(ACTIONS))
    for cn_name, slug, _png in ACTIONS:
        symbol = image_symbol(slug)
        if have_audio:
            lines.append('    { &%s, "%s", Lang::Sounds::OGG_ACT_%s },'
                         % (symbol, cn_name, slug.upper()))
        else:
            lines.append('    { &%s, "%s" },' % (symbol, cn_name))
    lines.append("}};")
    lines.append("")

    with open(MANIFEST_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    log("wrote manifest %s (ACTION_CARDS_HAVE_AUDIO=%d)"
        % (os.path.relpath(MANIFEST_PATH, PROJECT_DIR), 1 if have_audio else 0))


def write_choice_hint_header():
    """Emit extern declarations for CHOICE_HINT_IMAGES (no voice, not in kActionCards)."""
    lines = [
        "// Auto-generated by scripts/gen_action_cards.py - DO NOT EDIT.",
        "#pragma once",
        "",
        "#include <lvgl.h>",
        "",
    ]
    for slug, _png in CHOICE_HINT_IMAGES:
        lines.append("extern const lv_image_dsc_t %s;" % slug)
    lines.append("")
    os.makedirs(os.path.dirname(CHOICE_HINT_HEADER), exist_ok=True)
    with open(CHOICE_HINT_HEADER, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    log("wrote %s" % os.path.relpath(CHOICE_HINT_HEADER, PROJECT_DIR))


def main():
    parser = argparse.ArgumentParser(description="Generate action-cards firmware assets")
    parser.add_argument("--images", action="store_true", help="convert routine + hint PNGs to RGB565 C arrays")
    parser.add_argument("--audio", action="store_true", help="synthesize the 10 Chinese voice ogg clips")
    args = parser.parse_args()

    # Default to the always-offline-friendly image step when nothing is selected.
    do_images = args.images or not (args.images or args.audio)
    do_audio = args.audio

    if do_images:
        generate_images()
    if do_audio:
        generate_audio()
    write_manifest()
    write_choice_hint_header()


if __name__ == "__main__":
    main()
