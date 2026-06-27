package io.github.cotrin8672.kross.jdtls;

import java.io.IOException;
import java.nio.file.FileSystems;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardWatchEventKinds;
import java.nio.file.WatchKey;
import java.nio.file.WatchService;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import org.eclipse.core.resources.IProject;
import org.eclipse.core.resources.ResourcesPlugin;
import org.eclipse.core.runtime.CoreException;
import org.eclipse.core.runtime.IPath;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.jdt.core.IClasspathAttribute;
import org.eclipse.jdt.core.IClasspathEntry;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.jdt.core.JavaCore;
import org.eclipse.jdt.ls.core.internal.IDelegateCommandHandler;
import org.eclipse.jdt.ls.core.internal.JavaLanguageServerPlugin;
import org.eclipse.jdt.ls.core.internal.ProjectUtils;
import org.eclipse.jdt.ls.core.internal.managers.GradleBuildSupport;
import org.eclipse.jdt.ls.core.internal.managers.IBuildSupport;
import org.eclipse.jdt.ls.core.internal.managers.MavenBuildSupport;
import org.eclipse.jdt.ls.core.internal.managers.ProjectsManager.CHANGE_TYPE;

public final class SetKotlinBuildOutputCommandHandler implements IDelegateCommandHandler {
    private static final String COMMAND = "kotlin.java.setKotlinBuildOutput";
    private static final String MARKER = "kross";
    private static final Set<Path> WATCHED_OUTPUTS = new HashSet<>();

    @Override
    public Object executeCommand(String commandId, List arguments, IProgressMonitor monitor) throws Exception {
        if (!COMMAND.equals(commandId)) {
            return null;
        }
        if (arguments == null || arguments.isEmpty() || !(arguments.get(0) instanceof String output)) {
            throw new IllegalArgumentException("Expected Kotlin build output path as arguments[0]");
        }

        Path outputPath = Path.of(output).toAbsolutePath().normalize();
        if (!Files.isDirectory(outputPath)) {
            throw new IllegalArgumentException("Kotlin build output does not exist: " + outputPath);
        }

        for (IProject project : ResourcesPlugin.getWorkspace().getRoot().getProjects()) {
            if (monitor != null && monitor.isCanceled()) {
                return null;
            }
            if (!project.isAccessible() || !project.hasNature(JavaCore.NATURE_ID) || project.getLocation() == null) {
                continue;
            }

            IBuildSupport buildSupport = buildSupport(project);
            if (buildSupport == null) {
                continue;
            }

            Path projectPath = project.getLocation().toFile().toPath().toAbsolutePath().normalize();
            // ponytail: prefix match is the single-module MVP; map outputs to exact projects for multi-module support.
            if (!outputPath.startsWith(projectPath)) {
                continue;
            }

            setClasspathEntry(project, outputPath, monitor, buildSupport);
        }

        registerWatcher(outputPath);

        return null;
    }

    private static void setClasspathEntry(IProject project, Path outputPath, IProgressMonitor monitor, IBuildSupport buildSupport)
            throws CoreException {
        IJavaProject javaProject = JavaCore.create(project);
        if (javaProject == null || !javaProject.exists()) {
            return;
        }

        IPath krossPath = org.eclipse.core.runtime.Path.fromOSString(outputPath.toString());
        IPath sourcePath = sourcePathForOutput(project, outputPath);
        IClasspathEntry outputEntry = JavaCore.newLibraryEntry(
                krossPath,
                sourcePath,
                null,
                null,
                new IClasspathAttribute[] { JavaCore.newClasspathAttribute(MARKER, "true") },
                false);
        List<IClasspathEntry> entries = new ArrayList<>();
        for (IClasspathEntry entry : javaProject.getRawClasspath()) {
            if (!entry.getPath().equals(krossPath) && !isKrossEntry(entry)) {
                entries.add(entry);
            }
        }
        entries.add(outputEntry);
        javaProject.setRawClasspath(entries.toArray(IClasspathEntry[]::new), monitor);
        buildSupport.refresh(project, CHANGE_TYPE.CHANGED, monitor);
    }

    private static IPath sourcePathForOutput(IProject project, Path outputPath) {
        Path projectPath = project.getLocation().toFile().toPath().toAbsolutePath().normalize();
        // ponytail: single source dir is the Gradle JVM MVP; infer source sets if multi-source projects need it.
        Path sourcePath = projectPath.resolve("src/main/kotlin").normalize();
        if (!outputPath.startsWith(projectPath) || !Files.isDirectory(sourcePath)) {
            return null;
        }
        return org.eclipse.core.runtime.Path.fromOSString(sourcePath.toString());
    }

    private static synchronized void registerWatcher(Path outputPath) {
        if (!WATCHED_OUTPUTS.add(outputPath)) {
            return;
        }

        Thread thread = new Thread(() -> {
            try {
                Files.createDirectories(outputPath);
                WatchService watcher = FileSystems.getDefault().newWatchService();
                Map<WatchKey, Path> keys = watchDirectories(watcher, outputPath);
                while (true) {
                    WatchKey key = watcher.take();
                    Path dir = keys.get(key);
                    if (dir != null) {
                        key.pollEvents().forEach(event -> {
                            Path child = dir.resolve((Path) event.context());
                            if (event.kind() == StandardWatchEventKinds.ENTRY_CREATE && Files.isDirectory(child)) {
                                keys.putAll(watchDirectories(watcher, child));
                            }
                        });
                        Job job = new Job("Updating kross Kotlin classpath entry") {
                            @Override
                            protected IStatus run(IProgressMonitor monitor) {
                                try {
                                    for (IProject project : ResourcesPlugin.getWorkspace().getRoot().getProjects()) {
                                        IBuildSupport buildSupport = buildSupport(project);
                                        if (buildSupport != null) {
                                            setClasspathEntry(project, outputPath, monitor, buildSupport);
                                        }
                                    }
                                    return Status.OK_STATUS;
                                } catch (CoreException ex) {
                                    JavaLanguageServerPlugin.logException(ex);
                                    return Status.error("Failed to update kross Kotlin classpath entry");
                                }
                            }
                        };
                        job.schedule();
                        key.reset();
                    }
                }
            } catch (IOException | InterruptedException ex) {
                JavaLanguageServerPlugin.logException(ex);
                Thread.currentThread().interrupt();
            }
        }, "kross-kotlin-output-watcher");
        thread.setDaemon(true);
        thread.start();
    }

    private static Map<WatchKey, Path> watchDirectories(WatchService watcher, Path root) {
        Map<WatchKey, Path> keys = new HashMap<>();
        try {
            Files.walkFileTree(root, new SimpleFileVisitor<>() {
                @Override
                public FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes attrs) throws IOException {
                    WatchKey key = dir.register(watcher, StandardWatchEventKinds.ENTRY_CREATE,
                            StandardWatchEventKinds.ENTRY_DELETE, StandardWatchEventKinds.ENTRY_MODIFY);
                    keys.put(key, dir);
                    return FileVisitResult.CONTINUE;
                }
            });
        } catch (IOException ex) {
            JavaLanguageServerPlugin.logException(ex);
        }
        return keys;
    }

    private static boolean isKrossEntry(IClasspathEntry entry) {
        for (IClasspathAttribute attribute : entry.getExtraAttributes()) {
            if (MARKER.equals(attribute.getName()) && "true".equals(attribute.getValue())) {
                return true;
            }
        }
        return false;
    }

    private static IBuildSupport buildSupport(IProject project) {
        if (ProjectUtils.isMavenProject(project)) {
            return new MavenBuildSupport();
        }
        if (ProjectUtils.isGradleProject(project)) {
            return new GradleBuildSupport();
        }
        return null;
    }
}
