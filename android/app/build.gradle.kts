plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // Le plugin Flutter doit être après Android/Kotlin
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.musiclooper_clean"

    // Versions fournies par le plugin Flutter
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.example.musiclooper_clean"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Java/Kotlin 17 partout
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            // Clé debug pour permettre flutter run --release
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    // Chemin du projet Flutter
    source = "../.."
}