import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Google Services plugin đã bị bỏ — app không còn dùng Firebase.
    // google_sign_in hoạt động độc lập với Firebase (không cần plugin này).
}

// Keystore thật bắt buộc — KHÔNG fallback sang debug key.
// Nguồn keystore:
//   1. `android/key.properties` (local dev — đã trong .gitignore)
//   2. Env `KHONGDICH_KEYSTORE_BASE64` + password vars (CI secrets)
// Nếu cả hai đều thiếu → release build FAIL (debug-signed APK bị Google
// Play reject và SHA-1 không khớp OAuth client → đăng nhập Google lỗi).
data class KeystoreConfig(
    val file: File,
    val storePassword: String,
    val keyAlias: String,
    val keyPassword: String,
)

fun resolveKeystore(): KeystoreConfig? {
    // Local: android/key.properties (chuẩn Flutter).
    val propsFile = rootProject.file("key.properties")
    if (propsFile.isFile) {
        val p = Properties().apply {
            propsFile.inputStream().use { load(it) }
        }
        val file = File(propsFile.parentFile, p.getProperty("storeFile")).absoluteFile
        if (file.isFile) {
            return KeystoreConfig(
                file = file,
                storePassword = p.getProperty("storePassword"),
                keyAlias = p.getProperty("keyAlias"),
                keyPassword = p.getProperty("keyPassword"),
            )
        }
    }
    // CI: env base64 keystore.
    val env = System.getenv("KHONGDICH_KEYSTORE_BASE64")
    if (!env.isNullOrEmpty()) {
        val decoded = Base64.getDecoder().decode(env)
        val out = File(System.getProperty("java.io.tmpdir"), "khongdich-release.jks")
        out.writeBytes(decoded)
        return KeystoreConfig(
            file = out,
            storePassword = System.getenv("KHONGDICH_KEYSTORE_PASSWORD"),
            keyAlias = System.getenv("KHONGDICH_KEY_ALIAS"),
            keyPassword = System.getenv("KHONGDICH_KEY_PASSWORD"),
        )
    }
    return null
}

val releaseKeystore: KeystoreConfig? = resolveKeystore()

android {
    namespace = "com.khongdich.khongdich_mobile"
    // Hard-code compileSdk to 37 so all transitive AndroidX deps
    // (fragment 1.7+, window 1.2+, etc.) are happy — flutter_secure_storage
    // 11.x requires compileSdk >= 37. flutter.compileSdkVersion can lag at
    // 33/34 depending on the Flutter version, which trips AAR metadata checks.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications requires core library desugaring
        // (java.time on Android <26 isn't an issue since we set minSdk=26,
        // but the AAR metadata check still wants this flag set).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.khongdich.app"
        minSdk = maxOf(flutter.minSdkVersion, 26)  // Android 8.0+ per plan §1
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Required by flutter_local_notifications for desugar support.
        multiDexEnabled = true
    }

    // ─── Product flavors ────────────────────────────────────────────
    // The CI/CD pipeline builds two flavors:
    //   - demo → talks to https://demo.khongdich.com (QA testing)
    //   - prod  → talks to https://khongdich.com       (public)
    // The flavor is set via `flutter build apk --flavor=demo|prod`.
    // The `applicationIdSuffix` lets both flavors coexist on a single
    // device so QA can install demo + prod side-by-side.
    //
    // The actual backend URL is selected at runtime via the
    // `--dart-define=APP_ENV=demo|prod` flag (see lib/core/network/api_client.dart).
    //
    // Each flavor has its own `src/<flavor>/res/values/strings.xml`
    // with the app_name override ("Không Dịch (Demo)" vs "Không Dịch").
    // We avoid `resValue(...)` because AGP 9 gates custom resource
    // values in flavors behind an experimental flag.
    flavorDimensions += "environment"
    productFlavors {
        create("demo") {
            dimension = "environment"
            applicationIdSuffix = ".demo"
            versionNameSuffix = "-demo"
        }
        create("prod") {
            dimension = "environment"
        }
    }

    signingConfigs {
        create("release") {
            val ks = releaseKeystore
            check(ks != null) {
                "Không tìm thấy release keystore. Tạo android/key.properties " +
                    "(xem AGENTS.md) hoặc set KHONGDICH_KEYSTORE_BASE64 env."
            }
            storeFile = ks.file
            storePassword = ks.storePassword
            keyAlias = ks.keyAlias
            keyPassword = ks.keyPassword
        }
    }

    buildTypes {
        release {
            // Bắt buộc ký bằng key thật — KHÔNG fallback debug (debug-signed
            // APK bị Google Play reject + SHA-1 sai → Google Sign-In fail).
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
