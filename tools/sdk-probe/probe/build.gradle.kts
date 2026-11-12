plugins {
    id("com.android.application")
}

android {
    namespace = "com.seniornav.sdkprobe"
    compileSdk = 36

    defaultConfig {
        // 默认与主 App 同包名，这样一个 Android-端 AK 两处通用；
        // 代价是同一台手机上探针与主 App 只能装一个。想共存就传
        // -PprobeAppId=com.seniornav.sdkprobe 并为该包名另申请一个 AK。
        applicationId = (project.findProperty("probeAppId") as String?) ?: "com.seniornav.seniornav"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"

        // AK 只在构建期注入：-PbaiduAk=… 或环境变量 BAIDU_ANDROID_AK。
        // 源码与入库文件里不出现任何 AK。
        manifestPlaceholders["baiduAk"] =
            (project.findProperty("baiduAk") as String?)
                ?: System.getenv("BAIDU_ANDROID_AK")
                ?: ""
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // 只要检索组件：传递依赖 base → common，不引入 Map / Navi（ADR 0003）。
    implementation("com.baidu.lbsyun:BaiduMapSDK_Search:9.0.0")
}