#!/usr/bin/env python3
"""Chuyển markdown release notes -> plain text whatsnew cho Play Console.

Usage: md_to_whatsnew.py <input.md> <output>

Nguồn nội dung (theo thứ tự ưu tiên):

1. Khối viết tay trong file md:
       <!-- whatsnew:start -->
       ... bản tóm tắt dành riêng cho Play Console ...
       <!-- whatsnew:end -->
   Nội dung khối được strip markdown rồi đưa vào output — bắt buộc ≤ 500 ký tự
   (Play Console giới hạn, upload-google-play báo "notes ... is too long
   (max: 500)"). Vượt quá là LỖI — không auto-cắt khối viết tay, tác giả phải
   sửa lại khối (nội dung tóm tắt có chủ đích, cắt máy móc sẽ hỏng).

2. Không có khối: fallback strip toàn bộ file md (bỏ heading #, bullet -,
   **bold**, [link](url), `code`), gộp dòng trống thừa, cắt về tối đa 500 ký tự
   tại ranh giới dòng gần nhất + thêm "…" nếu bị cắt.
"""

import re
import sys

MAX_LEN = 500
START = "<!-- whatsnew:start -->"
END = "<!-- whatsnew:end -->"


def to_plain(md: str) -> str:
    """Strip markdown, giữ cấu trúc dòng."""
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
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def extract_block(md: str):
    """Nội dung khối whatsnew viết tay, hoặc None nếu không có marker."""
    starts = [m.start() for m in re.finditer(re.escape(START), md)]
    ends = [m.start() for m in re.finditer(re.escape(END), md)]
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] > ends[0]:
        print(
            "error: cần đúng 1 cặp "
            f"{START} ... {END} (đang có {len(starts)} start, {len(ends)} end, "
            "start phải đứng trước end)",
            file=sys.stderr,
        )
        raise SystemExit(3)
    return md[starts[0] + len(START):ends[0]]


def truncate(text: str) -> str:
    """Cắt về ≤ MAX_LEN tại ranh giới dòng gần nhất, thêm "…"."""
    head = MAX_LEN - 1
    cut = text.rfind("\n", 0, head)
    if cut < head * 3 // 4:  # ranh giới quá xa đầu đoạn cắt → cắt cứng
        cut = head
    return text[:cut].rstrip() + "…"


def to_whatsnew(md: str) -> str:
    block = extract_block(md)
    if block is not None:
        text = to_plain(block)
        if not text:
            print("error: khối whatsnew rỗng", file=sys.stderr)
            raise SystemExit(3)
        if len(text) > MAX_LEN:
            print(
                f"error: khối whatsnew dài {len(text)} ký tự > {MAX_LEN} "
                "(Play Console tối đa 500) — sửa lại khối trong release notes",
                file=sys.stderr,
            )
            raise SystemExit(3)
        return text
    text = to_plain(md)
    return truncate(text) if len(text) > MAX_LEN else text


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.md> <output>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as f:
        md = f.read()
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        f.write(to_whatsnew(md))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
