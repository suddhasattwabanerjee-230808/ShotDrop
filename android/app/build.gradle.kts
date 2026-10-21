plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bittu.shotdrop"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.bittu.shotdrop"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 10+: MediaStore RELATIVE_PATH and scoped storage without extra permissions.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release certificate: CI writes app/release.keystore from the
    // SHOTDROP_KEYSTORE_B64 secret and passes its password in
    // SHOTDROP_KEYSTORE_PASSWORD; it's never committed (backup:
    // /root/.shotdrop-signing on the phone). One fixed certificate is what lets
    // each release install over the last. SHA-1:
    //   0A:A7:3D:04:10:AD:CF:12:67:63:DD:83:7E:B5:AC:B7:E0:7B:F4:9B
    // Without the keystore (local builds) release falls back to debug signing.
    val releaseKeystore = file("release.keystore")
    val releasePassword = System.getenv("SHOTDROP_KEYSTORE_PASSWORD")
    val canSignRelease = releaseKeystore.exists() && !releasePassword.isNullOrEmpty()

    signingConfigs {
        if (canSignRelease) {
            create("release") {
                storeFile = releaseKeystore
                storeType = "PKCS12"
                storePassword = releasePassword
                keyAlias = "shotdrop"
                keyPassword = releasePassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (canSignRelease) "release" else "debug")
            ndk { abiFilters.add("arm64-v8a") }
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

dependencies {
    // FileProvider, for handing edited photos to Instagram / Facebook.
    implementation("androidx.core:core:1.13.1")
    // On-device pose detection for the body tools (model bundled, works offline).
    implementation("com.google.mlkit:pose-detection:18.0.0-beta5")
}
