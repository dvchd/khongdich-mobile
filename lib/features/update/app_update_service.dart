import 'package:in_app_update/in_app_update.dart';

/// Kết quả kiểm tra bản mới trên CH Play.
class AppUpdateCheck {
  const AppUpdateCheck({required this.available, this.versionCode});

  /// `true` khi CH Play có versionCode mới hơn bản đang cài.
  final bool available;

  /// versionCode (buildNumber) của bản mới — chỉ để log, không so sánh tay.
  final int? versionCode;
}

/// Trừu tượng hoá Play In-App Updates để provider/UI không phụ thuộc kiểu
/// plugin — test fake bằng [FakeAppUpdateService] mà không cần platform.
///
/// Plugin thật (`in_app_update`) chỉ hoạt động khi app được cài từ CH Play:
/// build debug/emulator hay APK sideload từ GitHub sẽ throw ngay ở
/// [check] — caller bắt lỗi và bỏ qua im lặng.
abstract class AppUpdateService {
  /// Kiểm tra CH Play có bản mới không.
  Future<AppUpdateCheck> check();

  /// Mở flow flexible update: Play hiện dialog xin phép rồi tải ngầm.
  /// Future resolve khi tải XONG (native resolve ở InstallStatus.DOWNLOADED);
  /// throw khi user từ chối consent hoặc lỗi tải.
  Future<void> startFlexibleDownload();

  /// Cài bản đã tải xong — Play tự đóng gói cài đặt và restart app.
  Future<void> completeInstall();
}

/// Implementation mặc định bọc thẳng plugin.
class PlayAppUpdateService implements AppUpdateService {
  const PlayAppUpdateService();

  @override
  Future<AppUpdateCheck> check() async {
    final info = await InAppUpdate.checkForUpdate();
    return AppUpdateCheck(
      available: info.updateAvailability == UpdateAvailability.updateAvailable,
      versionCode: info.availableVersionCode,
    );
  }

  @override
  Future<void> startFlexibleDownload() async {
    final result = await InAppUpdate.startFlexibleUpdate();
    if (result != AppUpdateResult.success) {
      // userDeniedUpdate / inAppUpdateFailed — không phải exception để
      // caller phân biệt "user từ chối" với "lỗi mạng/tải".
      throw StateError('Flexible update không hoàn tất: $result');
    }
  }

  @override
  Future<void> completeInstall() => InAppUpdate.completeFlexibleUpdate();
}
