plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.torchat.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.torchat.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        val devConfigFile = rootProject.projectDir.resolve("../../../infra/config/dev.env").canonicalFile
        val canonicalOnionUrl = devConfigFile.readLines()
            .firstOrNull { it.trim().startsWith("TORCHAT_ONION_URL=") }
            ?.substringAfter("=")?.trim().orEmpty()
        require(Regex("^https?://[a-z2-7]{56}\\.onion$").matches(canonicalOnionUrl)) {
            "Missing or invalid TORCHAT_ONION_URL in $devConfigFile"
        }
        buildConfigField("String", "TORCHAT_SERVER_URL", "\"$canonicalOnionUrl\"")
        manifestPlaceholders["torchatUsesCleartext"] = "false"
    }

    buildFeatures { buildConfig = true }

    buildTypes {
        debug {
            val devConfigFile = rootProject.projectDir.resolve("../../../infra/config/dev.env").canonicalFile
            val values = devConfigFile.readLines().mapNotNull { line ->
                val trimmed = line.trim()
                if (trimmed.isBlank() || trimmed.startsWith("#") || !trimmed.contains("=")) null
                else trimmed.substringBefore("=").trim() to trimmed.substringAfter("=").trim()
            }.toMap()
            val profile = System.getenv("TORCHAT_DEV_PROFILE")?.trim()?.ifBlank { null } ?: "Alice"
            require(profile == "Alice" || profile == "Bob") { "TORCHAT_DEV_PROFILE must be Alice or Bob" }
            val ownKey = values["TORCHAT_DEV_${profile.uppercase()}_KEY"].orEmpty()
            val peerName = if (profile == "Alice") "Bob" else "Alice"
            val peerKey = values["TORCHAT_DEV_${peerName.uppercase()}_KEY"].orEmpty()
            val devPair = System.getenv("TORCHAT_DEV_PAIR")?.lowercase() != "false"
            require(ownKey.isNotBlank() && peerKey.isNotBlank()) { "Missing development identity keys in $devConfigFile" }
            buildConfigField("String", "TORCHAT_DEV_PROFILE", "\"$profile\"")
            buildConfigField("String", "TORCHAT_DEV_IDENTITY_KEY", "\"$ownKey\"")
            buildConfigField("String", "TORCHAT_DEV_PEER_NAME", "\"$peerName\"")
            buildConfigField("String", "TORCHAT_DEV_PEER_KEY", "\"$peerKey\"")
            buildConfigField("boolean", "TORCHAT_DEV_PAIR", devPair.toString())
            // The development onion currently exposes HTTP inside Tor. The
            // transport code still rejects every non-v3-onion endpoint and
            // always supplies the local Tor SOCKS proxy.
            manifestPlaceholders["torchatUsesCleartext"] = "true"
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            buildConfigField("String", "TORCHAT_DEV_PROFILE", "\"\"")
            buildConfigField("String", "TORCHAT_DEV_IDENTITY_KEY", "\"\"")
            buildConfigField("String", "TORCHAT_DEV_PEER_NAME", "\"\"")
            buildConfigField("String", "TORCHAT_DEV_PEER_KEY", "\"\"")
            buildConfigField("boolean", "TORCHAT_DEV_PAIR", "false")
            manifestPlaceholders["torchatUsesCleartext"] = "false"
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("net.java.dev.jna:jna:5.14.0@aar")
    implementation("info.guardianproject:tor-android:0.4.8.19")
    implementation("info.guardianproject:jtorctl:0.4.5.7")
    implementation("net.zetetic:android-database-sqlcipher:4.5.4")
    implementation("androidx.sqlite:sqlite:2.4.0")
}
