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
// require compileSdk >= 34). Hooked via pluginManager.withPlugin so
// the override runs the moment the Android plugin is applied, before
// the project is evaluated.
subprojects {
    pluginManager.withPlugin("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
            compileSdk = 36
            defaultConfig.targetSdk = 36
        }
    }
    pluginManager.withPlugin("com.android.application") {
        extensions.configure<com.android.build.gradle.AppExtension>("android") {
            compileSdk = 36
            defaultConfig.targetSdk = 36
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
