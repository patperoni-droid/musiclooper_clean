#!/usr/bin/env bash
set -e

# 1) Démarre (ou réveille) l’émulateur préféré
# remplace par le nom exact de ton AVD si différent (ex: Pixel_7_API_36)
EMULATOR_NAME="Pixel_7_API_36"

if ! adb devices | grep -q emulator-; then
  echo ">> Launching emulator $EMULATOR_NAME"
  nohup "$ANDROID_HOME/emulator/emulator" -avd "$EMULATOR_NAME" >/dev/null 2>&1 &
  # attend qu'il soit prêt
  "$ANDROID_HOME/platform-tools/adb" wait-for-device
fi

# 2) Build propre (contourne le bug 'APK not found')
flutter clean
flutter pub get
./android/gradlew -p android :app:assembleDebug

# 3) Run en pointant l'APK réel
flutter run --use-application-binary=android/app/build/outputs/apk/debug/app-debug.apk