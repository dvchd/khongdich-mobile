import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/app.dart';
import 'package:khongdich_mobile/core/observability/app_logger.dart';

void main() {
  testWidgets('App boots to home screen with bottom nav', (tester) async {
    AppLogger.init();
    await tester.pumpWidget(
      const ProviderScope(
        child: KhongdichApp(),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Bottom navigation tabs are visible.
    expect(find.text('Trang chủ'), findsWidgets);
    expect(find.text('Tìm kiếm'), findsWidgets);
    expect(find.text('Tủ truyện'), findsWidgets);
    expect(find.text('Cá nhân'), findsWidgets);

    // App-bar title on the default Home tab.
    expect(find.text('Không Dịch'), findsWidgets);
  });
}
