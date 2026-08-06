pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Only for the ADB client library; scoped so nothing else resolves
        // here. The regex matters: libadb-android pulls in spake2-java, whose
        // group is com.github.MuntashirAkon.spake2-java, and an exact
        // includeGroup would leave that one to be hunted for on Maven Central,
        // where it does not exist.
        maven("https://jitpack.io") {
            content { includeGroupByRegex("com\\.github\\.MuntashirAkon.*") }
        }
    }
}

rootProject.name = "BT Juicer"
include(":app")
