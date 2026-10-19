import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Device tests have separate private storage; ordinary builds need no flavor.
val alignmentBenchmark = (project.findProperty("dart-defines") as? String)
    ?.split(",")?.any {
        String(Base64.getDecoder().decode(it)) == "QRM_ALIGNMENT_BENCHMARK=true"
    } == true

// Keep isolated debug/release packages mutually updatable without uninstalling
// their private model. Flutter otherwise adds 2000 only to split ARM64 releases,
// and Android rejects a subsequent debug downgrade from a non-debuggable APK.
if (alignmentBenchmark) {
    extra["force-version-code-ignoring-abi"] = true
}

android {
    namespace = "com.example.quran_reel_maker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (alignmentBenchmark) "com.example.quran_reel_maker.benchmark" else "com.example.quran_reel_maker"
        manifestPlaceholders["qrmAppLabel"] = if (alignmentBenchmark) "Quran Reel Benchmark" else "Quran Reel Maker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = if (alignmentBenchmark) 2000 + flutter.versionCode else flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.23.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
