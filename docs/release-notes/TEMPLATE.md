# Template release notes

Dùng cho mỗi bản phát hành — copy thành `docs/release-notes/vX.Y.Z.md` (tiếng Việt)
và `docs/release-notes/vX.Y.Z.en-US.md` (tiếng Anh), commit **TRƯỚC** khi chạy
`scripts/bump_version.sh` (script kiểm tra 2 file tồn tại + validate khối whatsnew).

## Vai trò từng phần

- **Body markdown** (các mục `## ...` bên dưới) → **GitHub Release** đọc thẳng
  (`body_path` trong CI). Viết đầy đủ, không giới hạn độ dài — đây là bản
  release notes "bình thường" cho người đọc repo/tester theo dõi GitHub.
- **Khối `<!-- whatsnew:start --> ... <!-- whatsnew:end -->`** → **Play Console**
  (Closed Testing). Bản tóm tắt viết tay, **tối đa 500 ký tự** (giới hạn cứng
  của Play Console). `scripts/md_to_whatsnew.py` fail ngay nếu vượt — không
  auto-cắt khối viết tay, sửa cho vừa rồi mới commit.
- Nếu **thiếu khối**, script fallback strip + cắt toàn body (mất phần sau,
  nội dung không kiểm soát được) — vì vậy **luôn viết khối này**.

## Luật viết khối whatsnew

- ≤ 500 ký tự kể cả dấu câu (đếm bằng `python3 -c "print(len(open('...').read()))"`
  hoặc chạy `python3 scripts/md_to_whatsnew.py <file> /dev/null` — fail tức là quá dài).
- Mỗi ý 1 dòng, thứ tự quan trọng giảm dần: tính năng lớn → tính năng nhỏ → sửa lỗi.
- Gộp nhiều mục liên quan vào 1 dòng (khác body viết chi tiết từng mục).
- Có thể dùng `**đậm**` — script tự strip khi sinh plain text.

## Mẫu (vi)

```markdown
## Tính năng mới

- **Đọc offline hoàn chỉnh**: tải chương kèm thông tin truyện + bìa — trang chi tiết
  truyện offline hiển thị y hệt online. Reader truyện đã tải là hybrid: đọc 100% offline,
  đọc/nghe liên tục khi có mạng.
- ...

## Sửa lỗi

- ...

## Kỹ thuật

- 206 tests xanh, `flutter analyze` 0 lỗi.

<!-- whatsnew:start -->
- Đọc offline hoàn chỉnh: tải chương kèm truyện + bìa, trang truyện offline y hệt online, đọc 100% offline.
- Bộ lọc tìm kiếm như web; trang chủ thêm Top flop, badge bình luận.
- Chi tiết truyện mới (bìa to + markdown + điểm uy tín); reader kiểu web: header chương, pill chương kế, lật trang kín trang.
- Nghe đọc liền mạch: now-playing bar toàn cục, notification về đúng chương đang nghe.
- Sửa: nút theo dõi kẹt, 3 lỗi runtime 0.4.2, Back, tìm kiếm 404, nhảy 2 chương, lỗi mạng có nút thử lại.
<!-- whatsnew:end -->
```

Khối ví dụ trên = 495 ký tự. Bản en-US dùng mục `## New features / ## Bug fixes / ## Tech`,
khối whatsnew ví dụ (497 ký tự):

```markdown
<!-- whatsnew:start -->
- Full offline reading: chapters saved with story info + cover; offline story page matches online.
- Web-style search filters; Home adds Top flop + comment badges.
- New story detail (big cover, markdown, trust score); web-style reader: chapter header, next-chapter pill, full page fill.
- Seamless listening: global now-playing bar, notification opens current chapter.
- Fixes: stuck follow button, 3 runtime bugs from 0.4.2, Back button, search 404, double chapter skip, retry on network errors.
<!-- whatsnew:end -->
```
