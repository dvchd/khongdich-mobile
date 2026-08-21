#!/usr/bin/env python3
"""Chuyển markdown release notes -> plain text whatsnew cho Play Console.

Usage: md_to_whatsnew.py <input.md> <output>
- Bỏ cú pháp markdown (heading #, bullet -, **bold**, [link](url), `code`).
- Giữ cấu trúc dòng, gộp dòng trống thừa, trim cuối.
"""

import re
import sys


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
    return text + "\n"


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
