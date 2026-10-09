plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val gameUrl = providers.gradleProperty("GAME_URL").orElse("https://YOUR_PUBLIC_GAME_HOST/").get()
val admobAppId = providers.gradleProperty("ADMOB_APP_ID").orElse("ca-app-pub-3940256099942544~3347511713").get()
val bannerAdUnitId = providers.gradleProperty("ADMOB_BANNER_AD_UNIT_ID").orElse("ca-app-pub-3940256099942544/9214589741").get()
val interstitialAdUnitId = providers.gradleProperty("ADMOB_INTERSTITIAL_AD_UNIT_ID").orElse("ca-app-pub-3940256099942544/1033173712").get()

android {
    namespace = "com.outland.game"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.outland.game"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        manifestPlaceholders["ADMOB_APP_ID"] = admobAppId
        buildConfigField("String", "GAME_URL", "\"$gameUrl\"")
        buildConfigField("String", "BANNER_AD_UNIT_ID", "\"$bannerAdUnitId\"")
        buildConfigField("String", "INTERSTITIAL_AD_UNIT_ID", "\"$interstitialAdUnitId\"")
    }

    buildFeatures {
        buildConfig = true
    }
}

dependencies {
    implementation("com.google.android.libraries.ads.mobile.sdk:ads-mobile-sdk:1.5.0")
}
