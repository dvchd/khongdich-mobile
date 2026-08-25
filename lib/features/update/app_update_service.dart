import 'package:in_app_update/in_app_update.dart';

/// Trạng thái cài đặt bản mới (thu gọn từ `InstallStatus` của plugin —
/// giữ các trạng thái có ý nghĩa với luồng app, không lộ kiểu plugin
/// ra ngoài service).
enum AppInstallStatus {
  /// Không rõ / không quan tâm.
  other,

  /// Đang tải ngầm.
  downloading,

  /// Đang cài.
  installing,

  /// Đã cài xong (hiếm khi thấy — app thường bị restart khi cài).
  installed,

  /// Tải xong, chờ cài — caller nên nhảy thẳng "Cài ngay".
  downloaded,

  /// Tải/cài thất bại.
  failed,

  /// User hủy.
  canceled,
}

/// Kết quả kiểm tra bản mới trên CH Play.
class AppUpdateCheck {
  const AppUpdateCheck({
    required this.available,
    this.versionCode,
    this.installStatus = AppInstallStatus.other,
  });

  /// `true` khi CH Play có versionCode mới hơn bản đang cài.
  final bool available;

  /// versionCode (buildNumber) của bản mới — chỉ để log, không so sánh tay.
  final int? versionCode;

  /// `downloaded` khi bản mới đã tải xong từ phiên trước — caller nên
  /// nhảy thẳng readyToInstall thay vì mời tải lại.
  final AppInstallStatus installStatus;
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
      installStatus: _mapInstallStatus(info.installStatus),
    );
  }

  static AppInstallStatus _mapInstallStatus(InstallStatus status) =>
      switch (status) {
        InstallStatus.downloading => AppInstallStatus.downloading,
        InstallStatus.installing => AppInstallStatus.installing,
        InstallStatus.installed => AppInstallStatus.installed,
        InstallStatus.downloaded => AppInstallStatus.downloaded,
        InstallStatus.failed => AppInstallStatus.failed,
        InstallStatus.canceled => AppInstallStatus.canceled,
        _ => AppInstallStatus.other,
      };

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
