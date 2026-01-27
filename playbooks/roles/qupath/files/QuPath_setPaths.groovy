import qupath.lib.gui.prefs.PathPrefs
import javafx.application.Platform

// Update this to the path where your extensions are
def extensionPath = "/opt/QuPath_Common_Data/extensions"

try {
    PathPrefs.getExtensionDirectoryProperty().set(extensionPath)
    println "Successfully set extension path to: " + extensionPath
} catch (Exception e) {
    println "Error setting path: " + e.getMessage()
}

Platform.exit()