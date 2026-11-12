pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    // 与主 App（app/android/settings.gradle.kts）同一版本，复用本机缓存。
    id("com.android.application") version "9.1.0" apply false
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "sdk-probe"
include(":probe")