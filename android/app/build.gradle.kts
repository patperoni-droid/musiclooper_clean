// android/app/build.gradle.kts

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // Le plugin Flutter doit être après Android/Kotlin
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.musiclooper_clean"

    // ✅ Compile avec la dernière API installée (Android 15 / API 36)
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.musiclooper_clean"
        minSdk = flutter.minSdkVersion            // ✅ version minimale supportée (Android 5.0)
        targetSdk = 34          // ✅ version ciblée (Android 14)
        versionCode = 1
        versionName = "1.0"
    }

    // ✅ Java/Kotlin 17 pour tout le projet
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            // Utilise la clé debug pour permettre flutter run --release sans config signée
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    // ✅ Chemin du projet Flutter (racine)
    source = "../.."
}
