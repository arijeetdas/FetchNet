import java.io.FileInputStream
import java.util.Properties

val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) load(FileInputStream(file))
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.fetchnet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

        signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    defaultConfig {
        applicationId = "com.fetchnet"
        // youtubedl-android (yt-dlp + Python + FFmpeg) requires API 24.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // yt-dlp's Python/FFmpeg are executed from nativeLibraryDir, so the
            // libraries must be extracted on install.
            useLegacyPackaging = true
            // Flutter has no x86 (32-bit) engine; don't ship the engine's x86 libs.
            excludes += "lib/x86/**"
            // libpython.zip.so / libffmpeg.zip.so are zip archives, not ELF files.
            keepDebugSymbols += "**/*.zip.so"
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreProperties.isEmpty) signingConfigs.getByName("debug")
                            else signingConfigs.getByName("release")
        }

    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    val ytdlVersion = "0.18.1"
    implementation("io.github.junkfood02.youtubedl-android:library:$ytdlVersion")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:$ytdlVersion")
    // 1.18 brings Live Update notification APIs and still compiles against SDK 36.
    implementation("androidx.core:core-ktx:1.18.0")
}

flutter {
    source = "../.."
}
