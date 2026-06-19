allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Force every plugin subproject (Flutter plugins like connectivity_plus,
// flutter_local_notifications, etc.) to compile against API 36 so the
// AndroidX AAR metadata check passes (fragment 1.7+, window 1.2+ all
// require compileSdk >= 34).
subprojects {
    afterEvaluate {
        if (project.hasProperty("android")) {
            val androidExt = project.extensions.findByName("android")
            if (androidExt is com.android.build.gradle.BaseExtension) {
                androidExt.compileSdkVersion(36)
                // Also bump targetSdk on libraries that set it.
                try {
                    androidExt.defaultConfig.targetSdkVersion(36)
                } catch (_: Throwable) {
                    // Some plugins don't expose targetSdk on defaultConfig; ignore.
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
