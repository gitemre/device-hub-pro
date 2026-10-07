# dmgbuild settings for Device Hub Pro's disk image (used by Scripts/package-app.sh).
#
# dmgbuild writes the window layout (.DS_Store) itself, so no Finder scripting
# and no Automation prompt is involved. package-app.sh passes:
#   -D app=<path to Device Hub Pro.app>  -D background=<packaging/dmg/background.tiff>
# The icon positions match Scripts/make-dmg-background.swift (arrow and caption).
import os.path

application = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
size = None

files = [application]
symlinks = {"Applications": "/Applications"}

icon_locations = {
    appname: (170, 190),
    "Applications": (490, 190),
}

background = defines["background"]  # noqa: F821
# The window frame includes the 28 pt title bar; the content stays 660 x 400,
# the background's size, so no scroll bar appears.
window_rect = ((200, 120), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
