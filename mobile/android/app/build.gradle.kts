import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Keep resolved Android/Flutter plugin dependencies reproducible in CI.
dependencyLocking {
    lockAllConfigurations()
}

val selectedConfigFile = System.getenv("TORCHAT_CONFIG_FILE")?.takeIf { it.isNotBlank() }
    ?.let { file(it).canonicalFile }
    ?: listOf(
        rootProject.projectDir.resolve("../../.torchat/runtime/local/environment.env"),
        rootProject.projectDir.resolve("../../infra/environments/local.env"),
    ).map { it.canonicalFile }.firstOrNull { it.isFile }
    ?: error("TorChat environment is missing. Run .\\scripts\\torchat.ps1 env up -Environment local")

fun configuredOnion(): String = selectedConfigFile.readLines()
    .firstOrNull { it.trim().startsWith("TORCHAT_ONION_URL=") }
    ?.substringAfter("=")?.trim().orEmpty()

android {
    namespace = "org.torchat.mobile"
    compileSdk = flutter.compileSdkVersion
    // Keep native ABI builds reproducible across Flutter SDK upgrades.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget = JvmTarget.JVM_17
        }
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
        val canonicalOnionUrl = configuredOnion()
        require(Regex("^https?://[a-z2-7]{56}\\.onion$").matches(canonicalOnionUrl)) {
            "Missing or invalid TORCHAT_ONION_URL in $selectedConfigFile. Run .\\scripts\\torchat.ps1 env up -Environment local"
        }
        buildConfigField("String", "TORCHAT_SERVER_URL", "\"$canonicalOnionUrl\"")
        manifestPlaceholders["torchatUsesCleartext"] = "false"
    }

    buildFeatures { buildConfig = true }

    sourceSets {
        getByName("main").jniLibs.setSrcDirs(
            listOf(layout.buildDirectory.dir("generated/jniLibs").get().asFile),
        )
    }

    buildTypes {
        debug {
            val values = selectedConfigFile.readLines().mapNotNull { line ->
                val trimmed = line.trim()
                if (trimmed.isBlank() || trimmed.startsWith("#") || !trimmed.contains("=")) null
                else trimmed.substringBefore("=").trim() to trimmed.substringAfter("=").trim()
            }.toMap()
            val profile = System.getenv("TORCHAT_DEV_PROFILE")?.trim()?.ifBlank { null } ?: ""
            require(profile.isEmpty() || profile == "Alice" || profile == "Bob") { "TORCHAT_DEV_PROFILE must be Alice or Bob when fixtures are enabled" }
            val ownKey = values["TORCHAT_DEV_${profile.uppercase()}_KEY"].orEmpty()
            val peerName = if (profile == "Alice") "Bob" else "Alice"
            val peerKey = values["TORCHAT_DEV_${peerName.uppercase()}_KEY"].orEmpty()
            val devPair = System.getenv("TORCHAT_DEV_PAIR")?.lowercase() == "true"
            if (devPair) {
                require(profile.isNotEmpty() && ownKey.isNotBlank() && peerKey.isNotBlank()) { "Fixture mode requires Alice/Bob keys in $selectedConfigFile" }
            }
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
            val releaseConfig = configuredOnion()
            val releaseTask = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
            if (releaseTask) {
                require(Regex("^https?://[a-z2-7]{56}\\.onion$").matches(releaseConfig)) {
                    "Release requires a generated v3 onion URL in $selectedConfigFile"
                }
            }
            buildConfigField("String", "TORCHAT_SERVER_URL", "\"$releaseConfig\"")
            // A release artifact must never silently fall back to the debug
            // certificate. CI supplies these values as environment variables;
            // developers can use the same names for a locally signed build.
            val storeFilePath = System.getenv("TORCHAT_RELEASE_STORE_FILE")
            val storePassword = System.getenv("TORCHAT_RELEASE_STORE_PASSWORD")
            val keyAlias = System.getenv("TORCHAT_RELEASE_KEY_ALIAS")
            val keyPassword = System.getenv("TORCHAT_RELEASE_KEY_PASSWORD")
            if (releaseTask) {
                require(!storeFilePath.isNullOrBlank() && !storePassword.isNullOrBlank()
                    && !keyAlias.isNullOrBlank() && !keyPassword.isNullOrBlank()) {
                    "Release signing requires TORCHAT_RELEASE_STORE_FILE, TORCHAT_RELEASE_STORE_PASSWORD, TORCHAT_RELEASE_KEY_ALIAS and TORCHAT_RELEASE_KEY_PASSWORD"
                }
                signingConfig = signingConfigs.create("torchatRelease") {
                    storeFile = file(storeFilePath)
                    this.storePassword = storePassword
                    this.keyAlias = keyAlias
                    this.keyPassword = keyPassword
                }
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    implementation("net.java.dev.jna:jna:5.14.0@aar")
    implementation("info.guardianproject:tor-android:0.4.8.19")
    implementation("info.guardianproject:jtorctl:0.4.5.7")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
