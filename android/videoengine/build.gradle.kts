import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
}

val abis: List<String> = providers.gradleProperty("videoengine.abis").get()
    .split(',').map(String::trim).filter(String::isNotEmpty)

// The planner vectors and the media fixtures live outside this module, shared with the Apple package.
val sharedDir: File = rootProject.projectDir.resolve("../shared")
val fixturesDir: File = rootProject.projectDir.resolve("../Tests/VideoEngineTests/Fixtures")

android {
    namespace = "io.github.nphil.videoengine"
    compileSdk = 36

    defaultConfig {
        // docs/PLATFORMS.md D5: Android 10 (API 29) is the floor, the same for every device the engine targets.
        minSdk = 29
        ndk { abiFilters += abis }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        abortOnError = true
        checkDependencies = false
        // Version bumps are reviewed changes here (Media3 is pinned exactly) and these two checks need the network.
        disable += setOf("GradleDependency", "NewerVersionAvailable")
        // docs/PLATFORMS.md D8 names arm64-v8a and armeabi-v7a as the targets; x86_64 (ChromeOS) is not one.
        disable += "ChromeOsAbiSupport"
    }

    testOptions {
        unitTests {
            // The planner and probe code builds on android.jar types; the tests only touch the parts that run on a JVM.
            isReturnDefaultValues = true
            all {
                it.systemProperty("videoengine.shared", sharedDir.path)
                it.systemProperty("videoengine.fixtures", fixturesDir.path)
                it.inputs.dir(sharedDir)
                it.inputs.dir(fixturesDir)
            }
        }
    }
}

kotlin {
    // Every public declaration is spelled out: the library's surface is what the Android apps compile against.
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    api(libs.androidx.media3.common)
    api(libs.androidx.media3.exoplayer)
    api(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.media3.inspector)
    implementation(libs.androidx.annotation)

    testImplementation(libs.junit)
    testImplementation(libs.org.json)
}
