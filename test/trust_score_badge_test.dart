import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/features/profile/profile_screen.dart';
import 'package:khongdich_mobile/repositories/story_repository.dart';

void main() {
  group('CurrentUser.trustScore', () {
    Map<String, dynamic> base() => {
          'id': 'u1',
          'username': 'dichkhong',
          'display_name': 'Dịch Không',
          'email': 'a@b.com',
          'role': 'author',
        };

    test('parse trust_score từ backend /auth/me', () {
      final u = CurrentUser.fromJson({...base(), 'trust_score': 68});
      expect(u.trustScore, 68);
    });

    test('mặc định 0 khi backend không trả', () {
      final u = CurrentUser.fromJson(base());
      expect(u.trustScore, 0);
    });
  });

  group('TrustScoreBadge', () {
    Future<void> pump(WidgetTester tester, int score) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TrustScoreBadge(score: score))),
        );

    Color? findBarColor(WidgetTester tester) {
      // Container màu trong FractionallySizedBox của thanh tiến trình.
      for (final w in tester.widgetList<Container>(find.byType(Container))) {
        if (w.color != null && w.color != Colors.black12) return w.color;
      }
      return null;
    }

    testWidgets('score >=70 → xanh (trust-high)', (tester) async {
      await pump(tester, 70);
      expect(find.text('70/100'), findsOneWidget);
      expect(findBarColor(tester), const Color(0xFF22C55E));
    });

    testWidgets('score 40-69 → vàng (trust-mid)', (tester) async {
      await pump(tester, 50);
      expect(find.text('50/100'), findsOneWidget);
      expect(findBarColor(tester), const Color(0xFFEAB308));
    });

    testWidgets('score <40 → đỏ (trust-low)', (tester) async {
      await pump(tester, 25);
      expect(find.text('25/100'), findsOneWidget);
      expect(findBarColor(tester), const Color(0xFFEF4444));
    });
  });
}