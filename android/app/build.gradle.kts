plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase: applies the Google Services plugin to this module.
    id("com.google.gms.google-services")
}

android {
    namespace = "com.solvanta.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (java.time back-port).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.solvanta.app"
        // local_auth 3 (app lock) requires API 24 (Android 7.0) and
        // mobile_scanner (QR ID scanning) API 23 — take whichever is higher.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    add("coreLibraryDesugaring", "com.android.tools:desugar_jdk_libs:2.1.4")

    // Firebase Android BoM — keeps Firebase library versions compatible.
    implementation(platform("com.google.firebase:firebase-bom:35.1.0"))
    // Google Analytics for Firebase (auto-collects on Android; no Dart code
    // required for basic session/screen events).
    implementation("com.google.firebase:firebase-analytics")
}

flutter {
    source = "../.."
}
