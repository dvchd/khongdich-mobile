import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/features/reader/views/chat_chapter_view.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';

void main() {
  final participants = [
    const ChatParticipant(id: 'c1', name: 'Lin Lan', color: '#FF0000'),
    const ChatParticipant(id: 'me', name: 'Bạn'),
  ];

  ChatMessage dialogue(String cid, String text) =>
      ChatMessage(id: 'm-$cid-$text', characterId: cid, content: text, messageType: 'dialogue');

  Future<void> pumpChat(
    WidgetTester tester,
    List<ChatMessage> messages,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ChatChapterView(
            participants: participants,
            messages: messages,
            onNext: () {},
            onPrev: () {},
          ),
        ),
      ),
    ));
    // initState reveal chạy trong post-frame callback.
    await tester.pump();
  }

  testWidgets('tin nhân vật khác: hiện "đang gõ..." rồi bubble (fast-forward bằng tap)',
      (tester) async {
    await pumpChat(tester, [dialogue('c1', 'Chào bạn!')]);

    // Ngay lập tức: chỉ báo đang gõ với tên nhân vật.
    expect(find.text('Lin Lan đang gõ...'), findsOneWidget);
    expect(find.text('Chào bạn!'), findsNothing);

    // Tap = fast-forward qua hiệu ứng gõ.
    await tester.tap(find.byType(ChatChapterView));
    await tester.pumpAndSettle();
    expect(find.text('Lin Lan đang gõ...'), findsNothing);
    expect(find.text('Chào bạn!'), findsOneWidget);
  });

  testWidgets('tin của "Bạn": giả thanh input gõ dần rồi tự gửi sang phải',
      (tester) async {
    await pumpChat(tester, [dialogue('me', 'Xin chào nha')]);

    // Đang ở trạng thái input typing — chưa có bubble.
    expect(find.text('Xin chào nha'), findsNothing);
    expect(find.byIcon(Icons.send), findsOneWidget);

    // Chờ đủ lâu: 350ms delay + 11 ký tự * 35ms + 450ms trễ gửi.
    await tester.pumpAndSettle();
    expect(find.text('Xin chào nha'), findsOneWidget);
    // Đã "gửi" — thanh input biến mất.
    expect(find.byIcon(Icons.send), findsNothing);
  });

  testWidgets('action/narration/system hiển thị đúng kiểu (nghiêng/giữa)',
      (tester) async {
    await pumpChat(tester, const [
      ChatMessage(id: 'm1', characterId: null, content: 'hít một hơi sâu', messageType: 'action'),
      ChatMessage(id: 'm2', characterId: null, content: 'Bầu trời tối sầm.', messageType: 'narration'),
      ChatMessage(id: 'm3', characterId: null, content: 'Hệ thống đã online', messageType: 'system'),
    ]);
    // Chuỗi tự nối: m1 hiện ngay → timer 150ms → m2 → 150ms → m3.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('✦ hít một hơi sâu'), findsOneWidget);
    final narration = tester.widget<Text>(find.text('Bầu trời tối sầm.'));
    expect(narration.style?.fontStyle, FontStyle.italic);
    expect(find.text('Hệ thống đã online'), findsOneWidget);
  });

  testWidgets('hết chương: text hiện ngay, nav xuất hiện sau delay 1200ms',
      (tester) async {
    await pumpChat(tester, [
      dialogue('c1', 'Một.'),
      dialogue('me', 'Hai.'),
    ]);
    // c1: chỉ báo đang gõ clamp(4*25=100→400ms).
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('Một.'), findsOneWidget);
    // "Bạn": prefill 350ms → gõ 4 ký tự * 35ms → trễ gửi 450ms → commit.
    await tester.pump(const Duration(milliseconds: 360));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Hai.'), findsOneWidget);
    expect(find.text('— hết chương —'), findsOneWidget);
    // Nav cuối chương xuất hiện sau delay 1200ms của web-mirror.
    expect(find.text('Sau'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(); // flush frame cho setState trong timer callback
    expect(find.text('Sau'), findsOneWidget);
  });
}
