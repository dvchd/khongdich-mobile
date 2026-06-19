import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Google Services plugin — reads `android/app/google-services.json`
    // (decoded from a CI secret) and injects the Firebase config into
    // the build. The plugin is a no-op when the file is absent, so
    // local `flutter run` still works without Firebase setup.
    id("com.google.gms.google-services")
}

// Decode a base64-encoded keystore (passed via env in CI) into a temp file.
// Local dev: fall back to the debug keystore when no release keystore is set.
fun keystoreFileFromEnv(): File? {
    val env = System.getenv("KHONGDICH_KEYSTORE_BASE64")
    if (env.isNullOrEmpty()) return null
    val decoded = Base64.getDecoder().decode(env)
    val out = File(System.getProperty("java.io.tmpdir"), "khongdich-release.jks")
    out.writeBytes(decoded)
    return out
}

android {
    namespace = "com.khongdich.khongdich_mobile"
    // Hard-code compileSdk to 36 so all transitive AndroidX deps
    // (fragment 1.7+, window 1.2+, etc.) are happy. flutter.compileSdkVersion
    // can lag at 33/34 depending on the Flutter version, which trips
    // AAR metadata checks.
    compileSdk = 36
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
        targetSdk = 36
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
    flavorDimensions += "environment"
    productFlavors {
        create("demo") {
            dimension = "environment"
            applicationIdSuffix = ".demo"
            versionNameSuffix = "-demo"
            // Match a distinct resValue so the launcher label says
            // "Không Dịch (Demo)" on the demo build.
            resValue("string", "app_name", "Không Dịch (Demo)")
        }
        create("prod") {
            dimension = "environment"
            resValue("string", "app_name", "Không Dịch")
        }
    }

    signingConfigs {
        create("release") {
            val ksFile = keystoreFileFromEnv()
            if (ksFile != null) {
                storeFile = ksFile
                storePassword = System.getenv("KHONGDICH_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KHONGDICH_KEY_ALIAS")
                keyPassword = System.getenv("KHONGDICH_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Use the release signing config if a keystore was supplied,
            // otherwise fall back to the debug signing config so local
            // `flutter build apk --release` still works.
            val ksFile = keystoreFileFromEnv()
            signingConfig = if (ksFile != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
