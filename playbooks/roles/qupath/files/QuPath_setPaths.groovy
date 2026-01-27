def targetStream = new FileInputStream( new File ( "qp_prefs.xml" ) )
println targetStream
PathPrefs.importPreferences( targetStream )

import qupath.lib.gui.prefs.PathPrefs