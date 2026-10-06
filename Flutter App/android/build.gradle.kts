allprojects {
    repositories {
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
// Some plugins (notably onnxruntime) pin an old compileSdk (android-33) that is
// lower than their transitive AndroidX dependencies require (>= 34), which fails
// the AAR metadata check. Force every Android subproject up to a modern
// compileSdk. Raising compileSdk for a library is backward compatible.
//
// Registered before the evaluationDependsOn block below, otherwise the forced
// evaluation makes afterEvaluate throw "project is already evaluated".
subprojects {
    afterEvaluate {
        val androidExt =
            extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        if (androidExt != null) {
            val current = androidExt.compileSdkVersion
                ?.substringAfter("android-")
                ?.toIntOrNull() ?: 0
            if (current < 35) {
                androidExt.compileSdkVersion(35)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
