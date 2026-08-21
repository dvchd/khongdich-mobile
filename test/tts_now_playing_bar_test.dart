import 'package:flutter_test/flutter_test.dart';

import 'package:khongdich_mobile/core/router/app_router.dart'
    show locationHasBottomNav;

/// Unit test cho vị trí của now-playing bar toàn cục: `locationHasBottomNav`
/// quyết định có cần chừa chỗ cho bottom nav không để bar không đè lên nav.
void main() {
  test('các tab MainShell có bottom nav', () {
    expect(locationHasBottomNav('/home'), isTrue);
    expect(locationHasBottomNav('/search'), isTrue);
    expect(locationHasBottomNav('/bookshelf'), isTrue);
    expect(locationHasBottomNav('/profile'), isTrue);
  });

  test('story detail online/offline có bottom nav', () {
    expect(locationHasBottomNav('/story/hello-world'), isTrue);
    expect(locationHasBottomNav('/offline-story/story-1'), isTrue);
  });

  test('reader và các màn khác không có bottom nav', () {
    expect(locationHasBottomNav('/chapter/story-1:5'), isFalse);
    expect(locationHasBottomNav('/chapter-offline/ch-1'), isFalse);
    expect(locationHasBottomNav('/settings'), isFalse);
    expect(locationHasBottomNav('/downloads'), isFalse);
    expect(locationHasBottomNav('/story-comments/story-1'), isFalse);
  });

  test('prefix /story/ không khớp nhầm /story-comments hoặc /story-reviews', () {
    expect(locationHasBottomNav('/story-comments/abc'), isFalse);
    expect(locationHasBottomNav('/story-reviews/abc'), isFalse);
  });
}
