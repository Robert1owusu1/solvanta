allprojects {
    repositories {
        // Local prefetch of Google-Maven artifacts: gradle.properties uses
        // 3min/10min HTTP timeouts with 6 retries, so a single slow fetch can
        // stall the build for 30+ minutes. Served from disk first.
        mavenLocal()
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
