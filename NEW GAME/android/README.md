# Outland Android

This Android Studio project wraps the existing browser game and displays AdMob ads in native Android views.

## Configure before running

1. Install Android Studio with JDK 17 and Android SDK Platform 35.
2. Set `GAME_URL` in `gradle.properties` to the public HTTPS URL serving `INDEX.HTML` and the multiplayer endpoints. A phone's `localhost` points to the phone, not the development PC.
3. Replace `ADMOB_APP_ID`, `ADMOB_BANNER_AD_UNIT_ID`, and `ADMOB_INTERSTITIAL_AD_UNIT_ID` with your AdMob values before release. The current values are Google's official test IDs; keep test IDs while developing.
4. Open the `android` folder in Android Studio, sync Gradle, and run on an emulator or device.

The banner stays below the game view. The interstitial is requested only at a match-end transition. Email sign-in and rooms use the same HTTPS host as the game page.

This workspace has no Java/Android SDK installed, so this wrapper has not been built locally. Before release, configure Google UMP consent flow for regions where it is required, verify your app-ads.txt, and test with your own registered app.
