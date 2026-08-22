#!/usr/bin/env python3
"""Chuyển markdown release notes -> plain text whatsnew cho Play Console.

Usage: md_to_whatsnew.py <input.md> <output>
- Bỏ cú pháp markdown (heading #, bullet -, **bold**, [link](url), `code`).
- Giữ cấu trúc dòng, gộp dòng trống thừa, trim cuối.
- Play Console giới hạn release notes 500 ký tự/ngôn ngữ (upload-google-play
  báo "notes ... is too long (max: 500)") — cắt về tối đa 500 ký tự tại ranh
  giới dòng gần nhất, thêm "…" nếu bị cắt.
"""

import re
import sys

MAX_LEN = 500


def to_plain(md: str) -> str:
    lines = []
    for raw in md.splitlines():
        line = raw.rstrip()
        line = re.sub(r"^\s*#{1,6}\s*", "", line)          # heading
        line = re.sub(r"^\s*[-*+]\s+", "- ", line)         # bullet giữ dấu gạch
        line = re.sub(r"\*\*([^*]+)\*\*", r"\1", line)     # bold
        line = re.sub(r"\*([^*]+)\*", r"\1", line)         # italic
        line = re.sub(r"`([^`]+)`", r"\1", line)           # inline code
        line = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)  # link
        lines.append(line)
    text = "\n".join(lines)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if len(text) > MAX_LEN:
        # Cắt tại ranh giới dòng gần nhất để không vỡ giữa chừng dòng.
        # Chừa 1 chỗ cho "…" — tổng ký tự sau khi thêm không vượt MAX_LEN.
        head = MAX_LEN - 1
        cut = text.rfind("\n", 0, head)
        if cut < head * 3 // 4:  # ranh giới quá xa đầu đoạn cắt → cắt cứng
            cut = head
        text = text[:cut].rstrip() + "…"
    return text


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.md> <output>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as f:
        md = f.read()
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        f.write(to_plain(md))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
