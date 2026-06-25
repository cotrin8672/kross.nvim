plugins {
    java
}

group = "io.github.cotrin8672.kross"
version = "0.2.0"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

dependencies {
    compileOnly("org.eclipse.jdt.ls:org.eclipse.jdt.ls.core:1.58.0.20260415140058")
    compileOnly("org.eclipse.platform:org.eclipse.core.resources:3.24.0")
    compileOnly("org.eclipse.platform:org.eclipse.core.runtime:3.34.200")
    compileOnly("org.eclipse.jdt:org.eclipse.jdt.core:3.46.0")
}

tasks.jar {
    archiveBaseName = "kross-jdtls"
    manifest {
        from("src/main/resources/META-INF/MANIFEST.MF")
    }
}
