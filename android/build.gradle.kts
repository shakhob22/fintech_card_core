group = "com.example.fintech_card_core"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.example.fintech_card_core"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24

        // ── cardcv (OpenCV FFI pre-processing core) ──────────────────────────
        // Built from ../src/CMakeLists.txt. When the OpenCV Android SDK path is
        // provided (Gradle property or env var), the full pipeline is compiled;
        // otherwise a tiny stub .so is built and the Dart layer falls back to
        // CardScan SSD OCR at runtime.
        externalNativeBuild {
            cmake {
                val opencvSdk =
                    (project.findProperty("fintechCardCore.opencvAndroidSdk") as? String)
                        ?: System.getenv("OPENCV_ANDROID_SDK")
                if (opencvSdk != null) {
                    arguments += "-DOPENCV_ANDROID_SDK=$opencvSdk"
                }
                cppFlags += "-O3"
            }
        }
    }

    androidResources {
        noCompress += "tflite"
    }

    externalNativeBuild {
        cmake {
            path = file("../src/CMakeLists.txt")
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    // CardScan SSD OCR (getbouncer MIT) — TFLite interpreter + bundled darknite model.
    implementation("org.tensorflow:tensorflow-lite:2.14.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
