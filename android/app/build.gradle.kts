import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase（推送）：必须在 com.android.application 之后应用
    id("com.google.gms.google-services")
}

// 正式签名（S12.6）：别名/口令写在 `android/key.properties`（**不进版本控制**，见仓库根 .gitignore），
// 证书文件是 `android/app/gracelink-release.keystore`（PKCS12 / RSA 4096 / 30 年 / CN=Gracelink）。
// 拿不到 key.properties 时（例如新机器刚 clone）退回 debug 签名 —— 不让 release 构建在配置阶段就崩。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "cc.gracelink.im"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications（消息通知）要求开启「核心库脱糖」：
        // 它在安卓 8 以下要用到 java.time 这些新 API，靠编译期补进来
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cc.gracelink.im"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 有正式证书就用它（直发 APK / 商店都用同一把钥匙）；
            // 没有（新机器还没放 key.properties）才退回模板默认的 debug 签名
            signingConfig = signingConfigs.getByName(
                if (hasReleaseKeystore) "release" else "debug",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
