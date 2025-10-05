// android/build.gradle.kts
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

subprojects {
    // Java 17 pour tout le monde
    tasks.withType<JavaCompile>().configureEach {
        sourceCompatibility = JavaVersion.VERSION_17.toString()
        targetCompatibility = JavaVersion.VERSION_17.toString()
        options.release.set(17)
    }
    // Kotlin 17 pour tout le monde
    tasks.withType(KotlinCompile::class.java).configureEach {
        kotlinOptions.jvmTarget = "17"
    }
}