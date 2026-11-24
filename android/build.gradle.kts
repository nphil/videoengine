// AGP 9 compiles Kotlin itself. The Kotlin plugin is declared here with `apply false` only so the compiler
// version in the catalog is the one used.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
}
