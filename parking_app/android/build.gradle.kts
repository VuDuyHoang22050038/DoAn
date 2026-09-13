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

subprojects {
    project.evaluationDependsOn(":app")
}

// =========================================================================
// ĐOẠN ÉP SDK 36 TOÀN DIỆN - TỰ ĐỘNG KHẮC PHỤC LỖI VÒNG ĐỜI VÀ GHI ĐÈ GRADLE
// =========================================================================
subprojects {
    val configureAndroid = {
        if (project.hasProperty("android")) {
            val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            android?.compileSdkVersion(36)
        }
    }

    // Nếu dự án đã biên dịch xong (evaluated), ép cấu hình ngay lập tức
    if (project.state.executed) {
        configureAndroid()
    } else {
        // Nếu chưa, đợi biên dịch xong rồi ghi đè để cấu hình 36 luôn là cuối cùng
        project.afterEvaluate {
            configureAndroid()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}