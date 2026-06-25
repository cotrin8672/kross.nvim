pluginManagement {
    repositories {
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven("https://repo.eclipse.org/content/repositories/jdtls-releases/")
        mavenCentral()
    }
}

rootProject.name = "kross.nvim"
