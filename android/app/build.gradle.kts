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
        }
    }

    // Keeps the APK small (0.4.0 was 56 MB, mostly native code):
    // - Every phone this goes on is 64-bit ARM, but ML Kit ships its native
    //   engine for 32-bit ARM and x86_64 too, and Flutter's plugin adds those
    //   ABIs back to any abiFilters set here, so they're dropped at packaging.
    // - Native code is stored compressed (Android unpacks it on install)
    //   rather than uncompressed, which is most of the download.
    packaging {
        jniLibs {
            excludes += setOf("**/armeabi-v7a/**", "**/x86/**", "**/x86_64/**")
            useLegacyPackaging = true
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
    // On-device person outline for Slim (model bundled, works offline).
    implementation("com.google.mlkit:segmentation-selfie:16.0.0-beta6")
    // On-device faces for the People filter and auto-turn (model bundled, works offline).
    implementation("com.google.mlkit:face-detection:16.1.7")
    // Runs MobileFaceNet (assets/MobileFaceNet.tflite), which tells people apart.
    implementation("org.tensorflow:tensorflow-lite:2.16.1")
    // Runs Remove People's models (person finder, outliner, LaMa). The models
    // themselves are downloaded on first use, not bundled.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.29.0")
}
