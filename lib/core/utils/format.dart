/// Nhóm hàng nghìn kiểu Việt Nam (12345 → 12.345).
///
/// Dùng chung cho mọi nơi hiển thị số đếm lớn: số từ/lượt đọc chương,
/// thống kê truyện, danh sách chương... Trước đây mỗi màn hình tự copy
/// một bản (`_fmtCount` / `_formatCount`) — giờ gộp về một chỗ.
String formatCount(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
    buf.write(s[i]);
  }
  return buf.toString();
}
