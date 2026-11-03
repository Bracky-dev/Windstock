import java.text.SimpleDateFormat
import java.util.Date
import java.util.TimeZone

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.chaquo.python")
}

// Stamped like the iOS build (CFBundleVersion = YYYYMMDD.HHMM), so a tester's
// log says exactly which APK they are on. versionCode must be an int that only
// grows: minutes since 2026-01-01 does that and fits comfortably.
val buildStamp: String = SimpleDateFormat("yyyyMMdd.HHmm").apply {
    timeZone = TimeZone.getTimeZone("UTC")
}.format(Date())
val buildCode: Int = ((System.currentTimeMillis() / 60000L) - 29_446_560L).toInt()

android {
    namespace = "com.windstock.launcher"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.windstock.launcher"
        minSdk = 24
        targetSdk = 35
        versionCode = buildCode
        versionName = "1.51 ($buildStamp)"
    }

    // Two apps from one source tree:
    //   launcher -- com.windstock.launcher, "Windstock": installs the 32-bit game as its own app.
    //   w64      -- com.windstock.windstock64, "Windstock 64": the game built in, run on 64-bit-only
    //               phones by translator64 (work/translator64) in this app's ":game" process.
    //               Built by tools/make_w64_apk.sh, which stages the translator and adds the game.
    flavorDimensions += "edition"
    productFlavors {
        create("launcher") {
            dimension = "edition"
            isDefault = true
            manifestPlaceholders["appLabel"] = "Windstock"
            buildConfigField("boolean", "GAME_BUILT_IN", "false")
            ndk {
                // armeabi-v7a so older 32-bit-only phones (32-bit CPUs, or arm64
                // chips shipped with a 32-bit Android) can install it too -- the
                // GAME is armeabi-v7a, so those phones are exactly the ones it
                // runs best on. Chaquopy ships 32-bit CPython only up to
                // 3.11, hence 3.11 (the server code is 3.9-clean).
                abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
            }
        }
        create("w64") {
            dimension = "edition"
            applicationId = "com.windstock.windstock64"
            manifestPlaceholders["appLabel"] = "Windstock 64"
            buildConfigField("boolean", "GAME_BUILT_IN", "true")
            // The game's own Java code (Unity, Niantic, Upsight) was written for API 23-era
            // Android: implicit PendingIntents, no foreground-service types. 30 is what
            // translator64 has been played on.
            targetSdk = 30
            // libzbridge.so links the EGL 1.5 entry points (API 29 stubs)
            minSdk = 29
            // translator64 is an arm64 host.
            ndk { abiFilters += listOf("arm64-v8a") }
        }
    }

    signingConfigs {
        create("windstock") {
            // A fixed key, so every build installs over the last one. Made by
            // tools/make_keystore.sh; see README.
            storeFile = rootProject.file("tools/windstock-launcher.jks")
            storePassword = "windstock"
            keyAlias = "windstock"
            keyPassword = "windstock"
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("windstock")
        }
        getByName("debug") {
            signingConfig = signingConfigs.getByName("windstock")
        }
    }

    sourceSets {
        getByName("main") {
            // The server, the game APK and the world data are staged here by
            // tools/stage_*.sh -- hundreds of MB that do not belong in git.
            assets.srcDirs("src/main/assets", "../Staging/assets")
        }
        getByName("w64") {
            // The game host (work/translator64/zb-app): Chucny's Translator runtime (AGPL-3.0) with
            // our Windstock additions; its Java side keeps its packages (libzbridge.so calls back
            // into com.windstock.translator64 and serves com.chucny.translator.core).
            java.srcDirs("../../work/translator64/zb-app/java")
            // libzbridge.so, the arm64 Frida gadget + t64 agent; the runtime (assets/zbrt/**) and
            // the guest libs (assets/guest/**). Staged by tools/make_w64_apk.sh.
            jniLibs.srcDirs("../Staging/w64/jniLibs")
            assets.srcDirs("../Staging/w64/assets")
        }
    }

    androidResources {
        // Already compressed or read at an offset: storing them avoids a
        // second inflate on every first run.
        noCompress += listOf("apk", "sqlite", "zip", "png", "bin")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        // Windstock 64: the gadget's .script.so / .config.so are text, not ELF -- don't strip them
        jniLibs.keepDebugSymbols += "**/libfrida-gadget*.so"
    }
}

androidComponents {
    // Windstock 64 only: the Frida gadget reads its .config.so / .script.so next to itself,
    // so the native libs have to be extracted to files in nativeLibraryDir.
    onVariants(selector().withFlavor("edition" to "w64")) {
        it.packaging.jniLibs.useLegacyPackaging.set(true)
    }
}

chaquopy {
    defaultConfig {
        version = "3.11"
        pyc {
            // No matching build Python on the Mac is required this way; the
            // phone compiles on first import and caches the result.
            src = false
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.09.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.3")
    implementation("androidx.navigation:navigation-compose:2.9.4")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
}
