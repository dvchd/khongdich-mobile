import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.khongdich.app"
        minSdk = maxOf(flutter.minSdkVersion, 26)  // Android 8.0+ per plan §1
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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

flutter {
    source = "../.."
}
