# Evaluated by dmgbuild; all paths are supplied by package-dmg.sh.
format = "UDZO"
filesystem = "HFS+"
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
icon_locations = {
    "Disk Inventory X2.app": (170, 210),
    "Applications": (550, 210),
}
window_rect = ((280, 160), (720, 440))
default_view = "icon-view"
include_icon_view_settings = True
icon_size = 96
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
