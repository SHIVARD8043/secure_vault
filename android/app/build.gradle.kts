import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 👈 1. లోకల్ గా ఉన్న కీ.ప్రాపర్టీస్ ని లోడ్ చేస్తున్నాం
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.secure_vault"
    compileSdk = 37
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.secure_vault"
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // 👈 2. గిట్‌హబ్ లో ఉంటే env, లేదంటే లోకల్ key.properties నుండి వాల్యూస్ తీసుకుంటుంది
            storeFile = file(System.getenv("KEYSTORE_PATH") ?: keystoreProperties.getProperty("storeFile") ?: "upload-keystore.jks")
            storePassword = System.getenv("STORE_PASSWORD") ?: keystoreProperties.getProperty("storePassword")
            keyAlias = System.getenv("KEY_ALIAS") ?: keystoreProperties.getProperty("keyAlias")
            keyPassword = System.getenv("KEY_PASSWORD") ?: keystoreProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
        // 👈 3. డీబగ్ (లోకల్ రన్) కి కూడా రిలీజ్ సంతకమే పెడుతున్నాం
        getByName("debug") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// EXIF metadata writing support for editing existing image files.
dependencies {
    implementation("androidx.exifinterface:exifinterface:1.3.7")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
