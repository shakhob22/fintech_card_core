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
        // the ML Kit multi-pass path at runtime.
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
    // Native ML Kit text recognition — replaces the google_mlkit_text_recognition Flutter package.
    // All OCR logic is wired through our own fintech_card_core/ocr MethodChannel.
    implementation("com.google.mlkit:text-recognition:16.0.1")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
