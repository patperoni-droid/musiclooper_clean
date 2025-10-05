# MusicLooper — Mémo build (Android)

## Versions connues OK
- Flutter: `flutter --version` (à compléter)
- Gradle Plugin: tel que généré par `flutter create .`
- JDK: 17
- compileSdk: 36
- targetSdk: 34
- minSdk: 21
- Emulator: Pixel 7 – API 36

## Fichiers importants
- android/app/build.gradle.kts
    - compileSdk = 36
    - minSdk = 21
    - targetSdk = 34
    - Java/Kotlin 17 (compileOptions + kotlinOptions)
- android/build.gradle.kts (racine Android)
    - bloc `subprojects` qui neutralise `--release`
    - Java/Kotlin 17 forcés

## Commandes rapides
- Lancer sur émulateur : `./run_emulator.sh`
- Si Flutter dit "APK not found":