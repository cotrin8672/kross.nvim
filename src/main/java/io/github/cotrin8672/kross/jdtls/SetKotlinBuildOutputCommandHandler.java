package io.github.cotrin8672.kross.jdtls;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import org.eclipse.core.resources.IProject;
import org.eclipse.core.resources.IResource;
import org.eclipse.core.resources.ResourcesPlugin;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.jdt.core.IClasspathAttribute;
import org.eclipse.jdt.core.IClasspathEntry;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.jdt.core.JavaCore;
import org.eclipse.jdt.ls.core.internal.IDelegateCommandHandler;
import org.eclipse.jdt.ls.core.internal.ProjectUtils;
import org.eclipse.jdt.ls.core.internal.managers.GradleBuildSupport;
import org.eclipse.jdt.ls.core.internal.managers.IBuildSupport;
import org.eclipse.jdt.ls.core.internal.managers.MavenBuildSupport;
import org.eclipse.jdt.ls.core.internal.managers.ProjectsManager.CHANGE_TYPE;

public final class SetKotlinBuildOutputCommandHandler implements IDelegateCommandHandler {
    private static final String COMMAND = "kotlin.java.setKotlinBuildOutput";
    private static final String MARKER = "kross";

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

            IJavaProject javaProject = JavaCore.create(project);
            if (javaProject == null || !javaProject.exists()) {
                continue;
            }

            IClasspathEntry outputEntry = JavaCore.newLibraryEntry(
                    org.eclipse.core.runtime.Path.fromOSString(outputPath.toString()),
                    null,
                    null,
                    null,
                    new IClasspathAttribute[] { JavaCore.newClasspathAttribute(MARKER, "true") },
                    false);
            List<IClasspathEntry> entries = new ArrayList<>();
            for (IClasspathEntry entry : javaProject.getRawClasspath()) {
                if (!isKrossEntry(entry)) {
                    entries.add(entry);
                }
            }
            entries.add(outputEntry);
            javaProject.setRawClasspath(entries.toArray(IClasspathEntry[]::new), monitor);
            project.refreshLocal(IResource.DEPTH_INFINITE, monitor);
            buildSupport.refresh(project, CHANGE_TYPE.CHANGED, monitor);
        }

        return null;
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
