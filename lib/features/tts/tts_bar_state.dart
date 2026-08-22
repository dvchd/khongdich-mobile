import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ModalRoute, NavigatorObserver, Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Trạng thái hiển thị của [TtsNowPlayingBar]:
///
///   - `sheetOpen`: có modal sheet/dialog đang mở không (TTS control
///     panel, settings đọc, share, report…) — bar tự ẩn khi sheet mở.
///     Được cập nhật tự động qua [TtsBarRouteObserver].
///
/// ChangeNotifier (không phải StateProvider) để người nghe dùng
/// ListenableBuilder — bar ghi giá trị ngay trong build của nó; notify
/// chỉ xảy ra khi giá trị ĐỔI nên không tạo vòng lặp rebuild.
class TtsBarState extends ChangeNotifier {
  bool _sheetOpen = false;
  bool get sheetOpen => _sheetOpen;

  void setSheetOpen(bool value) {
    if (value == _sheetOpen) return;
    _sheetOpen = value;
    notifyListeners();
  }
}

final ttsBarStateProvider = Provider<TtsBarState>((ref) => TtsBarState());

/// Đếm các modal route (bottom sheet / dialog — `ModalRoute` có barrier
/// dismissible) đang mở trên navigator. Gắn vào GoRouter qua `observers:`.
/// Bar đọc [TtsBarState.sheetOpen] để ẩn khi có sheet mở — nếu không bar
/// (nổi TRÊN Navigator) vẫn đè lên đáy sheet (vd. reader settings đã bị
/// bar che mất nút "Cuộn dọc/Lật trang").
class TtsBarRouteObserver extends NavigatorObserver {
  TtsBarRouteObserver(this._barState);

  final TtsBarState _barState;
  final Set<Route<dynamic>> _modalRoutes = {};

  bool _isModal(Route<dynamic> route) =>
      route is ModalRoute<dynamic> &&
      route.barrierDismissible &&
      route.overlayEntries.isNotEmpty;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    debugPrint(
        'TTS-ROUTE: push ${route.runtimeType} barrier=${route is ModalRoute ? route.barrierDismissible : 'n/a'}');
    if (_isModal(route)) {
      _modalRoutes.add(route);
      _barState.setSheetOpen(true);
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    debugPrint('TTS-ROUTE: pop ${route.runtimeType}');
    if (_modalRoutes.remove(route)) {
      _barState.setSheetOpen(_modalRoutes.isNotEmpty);
    }
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_modalRoutes.remove(route)) {
      _barState.setSheetOpen(_modalRoutes.isNotEmpty);
    }
    super.didRemove(route, previousRoute);
  }
}