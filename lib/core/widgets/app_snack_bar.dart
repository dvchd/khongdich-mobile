import 'package:flutter/material.dart';

/// Hiện SnackBar — thông báo custom của app (Flutter render qua
/// ScaffoldMessenger, KHÔNG phải notification của hệ điều hành).
///
/// Không cần margin đặc biệt khi TTS now-playing bar đang hiển thị: bar
/// giờ là phần tử THỰC trong layout (root Column cho route không có
/// bottom nav, slot bottomNavigationBar cho màn hình có menu) nên
/// Scaffold tự thu hẹp nội dung và SnackBar tự nổi trên vùng đáy —
/// không còn bị bar nổi che như trước.
void showAppSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: duration));
}
