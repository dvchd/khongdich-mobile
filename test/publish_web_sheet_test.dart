import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/features/home/publish_web_sheet.dart';

void main() {
  group('PublishWebSheet (đăng truyện trên web)', () {
    testWidgets('hiển thị 3 bước hướng dẫn + nút mở web', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: PublishWebSheet())),
        ),
      );
      expect(find.text('Đăng truyện'), findsOneWidget);
      expect(find.textContaining('trình duyệt web'), findsOneWidget);
      expect(find.text('Mở web đăng truyện'), findsOneWidget);
      expect(find.text('Để sau'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('bấm "Mở web đăng truyện" không crash khi không có trình duyệt',
        (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: PublishWebSheet())),
        ),
      );
      // Trong widget test không có platform channel của url_launcher —
      // cuộc gọi launchUrl no-op (không throw, không mở). Điều quan trọng:
      // sheet không được crash, vẫn giữ nguyên trạng thái.
      await tester.tap(find.text('Mở web đăng truyện'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('Mở web đăng truyện'), findsOneWidget);
    });

    testWidgets('bấm "Để sau" đóng sheet', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: PublishWebSheet())),
        ),
      );
      await tester.tap(find.text('Để sau'));
      await tester.pumpAndSettle();
      // Sheet tự pop; body trống sau khi đóng.
      expect(find.text('Đăng truyện'), findsNothing);
    });
  });
}