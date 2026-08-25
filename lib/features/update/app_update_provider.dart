import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/observability/app_logger.dart';
import 'app_update_service.dart';

/// Giai đoạn của luồng cập nhật in-app (CH Play In-App Updates).
enum AppUpdatePhase {
  /// Chưa check / không có bản mới / check lỗi — mọi trường hợp im lặng.
  idle,

  /// Có bản mới — banner mời cập nhật trên Trang chủ.
  available,

  /// User bấm "Cập nhật" — Play đang tải ngầm.
  downloading,

  /// Tải xong — chờ user chạm "Cài ngay" (snackbar + banner nhắc).
  readyToInstall,
}

class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.dismissed = false,
  });

  final AppUpdatePhase phase;

  /// "Để sau" — ẩn banner trong PHIÊN hiện tại (không persist: lần mở app
  /// sau vẫn check lại, đúng tinh thần best-effort của tính năng).
  final bool dismissed;

  bool get showBanner => !dismissed && phase != AppUpdatePhase.idle;

  AppUpdateState copyWith({AppUpdatePhase? phase, bool? dismissed}) =>
      AppUpdateState(
        phase: phase ?? this.phase,
        dismissed: dismissed ?? this.dismissed,
      );
}

final appUpdateServiceProvider = Provider<AppUpdateService>(
  (ref) => const PlayAppUpdateService(),
);

/// Check-on-start: Home gọi [AppUpdateNotifier.checkOnce] đúng một lần
/// mỗi phiên. Không poll — một IPC tới Play mỗi lần mở app là đủ, và
/// `availableVersionCode` chỉ đổi sau khi CI upload AAB mới lên track.
class AppUpdateNotifier extends Notifier<AppUpdateState> {
  @override
  AppUpdateState build() => const AppUpdateState();

  /// Kiểm tra CH Play có bản mới không. Bất kỳ lỗi nào (không phải bản
  /// cài Play, offline, Play đang xử lý AAB...) đều im lặng về idle —
  /// tính năng này KHÔNG được làm phiền user khi không dùng được.
  Future<void> checkOnce() async {
    if (state.phase != AppUpdatePhase.idle) return; // đã có kết quả
    try {
      final result = await ref.read(appUpdateServiceProvider).check();
      if (!result.available) return;
      AppLogger.info(
        'AppUpdate: có bản mới trên CH Play '
        '(build ${result.versionCode ?? '?'})',
      );
      state = state.copyWith(phase: AppUpdatePhase.available);
    } catch (e, s) {
      AppLogger.info('AppUpdate: bỏ qua check (không phải bản cài Play)', e, s);
    }
  }

  /// "Để sau" — ẩn banner phiên này.
  void dismiss() => state = state.copyWith(dismissed: true);

  /// Bắt đầu tải flexible update. Resolve khi tải xong → readyToInstall;
  /// lỗi / user từ chối consent → quay lại available để thử lại.
  Future<void> startDownload() async {
    if (state.phase != AppUpdatePhase.available) return;
    state = state.copyWith(phase: AppUpdatePhase.downloading);
    try {
      await ref.read(appUpdateServiceProvider).startFlexibleDownload();
      if (state.phase == AppUpdatePhase.downloading) {
        state = state.copyWith(phase: AppUpdatePhase.readyToInstall);
      }
    } catch (e, s) {
      AppLogger.warning('AppUpdate: tải thất bại', e, s);
      if (state.phase == AppUpdatePhase.downloading) {
        state = state.copyWith(phase: AppUpdatePhase.available);
      }
    }
  }

  /// "Cài ngay" — Play cài đặt và restart app. Lỗi cài là hiếm; giữ
  /// readyToInstall để user thử lại.
  Future<void> installDownloaded() async {
    if (state.phase != AppUpdatePhase.readyToInstall) return;
    try {
      await ref.read(appUpdateServiceProvider).completeInstall();
    } catch (e, s) {
      AppLogger.warning('AppUpdate: cài thất bại', e, s);
    }
  }
}

final appUpdateProvider = NotifierProvider<AppUpdateNotifier, AppUpdateState>(
  AppUpdateNotifier.new,
);
