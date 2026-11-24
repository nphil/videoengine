import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import javax.inject.Inject

plugins {
    alias(libs.plugins.android.application)
}

val abis: List<String> = providers.gradleProperty("videoengine.abis").get()
    .split(',').map(String::trim).filter(String::isNotEmpty)

/** Copies the repository's test videos and their ffprobe manifest into the app's assets, so no binary is duplicated in git. */
abstract class CopyFixtures : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val videos: DirectoryProperty

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val manifest: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @get:Inject
    abstract val files: FileSystemOperations

    @TaskAction
    fun copy() {
        files.sync {
            into(outputDir.dir("fixtures"))
            from(videos) { include("*.mkv") }
            from(manifest) { include("manifest.json") }
        }
    }
}

android {
    namespace = "io.github.nphil.videoengine.sample"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.nphil.videoengine.sample"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-stage1"
        ndk { abiFilters += abis }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The fixtures are played straight from the APK, so they must stay uncompressed.
    androidResources { noCompress += "mkv" }

    lint {
        abortOnError = true
        disable += setOf("GradleDependency", "NewerVersionAvailable", "ChromeOsAbiSupport")
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

androidComponents {
    onVariants { variant ->
        val copy = tasks.register<CopyFixtures>("copy${variant.name.replaceFirstChar { it.uppercase() }}Fixtures") {
            videos.set(rootProject.layout.projectDirectory.dir("../Tests/VideoEngineTests/Fixtures"))
            manifest.set(rootProject.layout.projectDirectory.dir("../shared/fixtures"))
        }
        variant.sources.assets?.addGeneratedSourceDirectory(copy, CopyFixtures::outputDir)
    }
}

dependencies {
    implementation(project(":videoengine"))
    implementation(libs.androidx.media3.ui)
    implementation(libs.kotlinx.coroutines.android)
}
