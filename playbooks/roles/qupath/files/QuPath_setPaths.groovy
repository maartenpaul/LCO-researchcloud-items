import qupath.lib.gui.prefs.QuPathPrefs
import javafx.application.Platform

// We use the path where we extracted the Zenodo files
def extensionPath = "/opt/QuPath_Common_Data/extensions"
def file = new File(extensionPath)

if (file.exists()) {
    // Set the extension directory in QuPath's internal preferences
    QuPathPrefs.extensionDirectoryProperty().set(file.getAbsolutePath())
    println "QuPath extension path set to: " + file.getAbsolutePath()
} else {
    println "Warning: Extension path not found at " + extensionPath
}

// Ensure preferences are flushed/saved
// QuPath usually does this on exit, but calling a preference check helps
Platform.exit()