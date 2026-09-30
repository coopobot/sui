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

// 统一抬升所有 Android 子工程的 compileSdk 到 36。
// 背景：部分 pub 插件（如 file_picker 8.x）把自身 android 模块的 compileSdk 钉在 34，
// 而其依赖（flutter_plugin_android_lifecycle 等）通过 AAR metadata 要求依赖方
// 至少编译于 API 36，于是 `:file_picker:checkReleaseAarMetadata` 直接失败；
// 属插件侧版本问题，只能在此处对所有子工程做全局覆盖（详见 SuiDevAgent/Agents.md §5.3）。
//
// 注意：本块必须注册在下面的 evaluationDependsOn(":app") 之前。
// 该语句会立即触发 :app 求值，若在其之后再注册 afterEvaluate，
// Gradle 会报 "Cannot run Project.afterEvaluate(Action) when the project is already evaluated"。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        listOf("compileSdk", "compileSdkVersion").forEach { name ->
            runCatching { androidExt.withGroovyBuilder { setProperty(name, 36) } }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
