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

// NOTE: removed `subprojects { project.evaluationDependsOn(":app") }`
// — it was forcing plugin subprojects to evaluate before our
// `pluginManager.withPlugin` hook below could fire, which meant the
// compileSdk override was applied too late (after the plugin was
// already configured against compileSdk=33).

// Force every plugin subproject (Flutter plugins like connectivity_plus,
// flutter_local_notifications, etc.) to compile against API 36 so the
// AndroidX AAR metadata check passes (fragment 1.7+, window 1.2+ all
// require compileSdk >= 34).
subprojects {
    pluginManager.withPlugin("com.android.library") {
        val ext = extensions.findByName("android") as? com.android.build.gradle.LibraryExtension
        ext?.apply {
            compileSdkVersion(36)
            defaultConfig.targetSdkVersion(36)
        }
    }
    pluginManager.withPlugin("com.android.application") {
        val ext = extensions.findByName("android") as? com.android.build.gradle.AppExtension
        ext?.apply {
            compileSdkVersion(36)
            defaultConfig.targetSdkVersion(36)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
