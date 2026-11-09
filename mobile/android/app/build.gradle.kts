import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing reads android/key.properties, which is git-ignored:
//   storeFile=/absolute/path/to/netzero-upload.jks
//   storePassword=...
//   keyAlias=upload
//   keyPassword=...
// Without that file, release builds use the debug key so `flutter run --release` still works locally.
// A build signed that way can't be uploaded to Google Play.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties =
    Properties().apply {
        if (keystorePropertiesFile.exists()) FileInputStream(keystorePropertiesFile).use { load(it) }
    }
val hasReleaseKey = keystorePropertiesFile.exists()

android {
    namespace = "mn.everestsolution.netzero"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "mn.everestsolution.netzero"
        // Android 8.0, the oldest version sentry_flutter 10 supports.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Both come from the version line in pubspec.yaml.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
