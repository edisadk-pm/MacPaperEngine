# The disk image's layout, read by dmgbuild (see Packaging/make-dmg.sh): the app on the left, a
# link to Applications on the right, and a background with an arrow between them.
app = defines["app"]

format = "UDZO"
filesystem = "HFS+"
icon = defines["icon"]

files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]
# The frame, title bar included. Tall enough for the stamps at the bottom of the background to show
# whole, even with Finder's path bar.
window_rect = ((200, 120), (600, 480))
default_view = "icon-view"
icon_size = 112
text_size = 13
icon_locations = {
    "MacPaperEngine.app": (165, 175),
    "Applications": (435, 175),
    # Hidden files, beside the window for anyone who has Finder show them.
    ".background.tiff": (760, 175),
    ".VolumeIcon.icns": (900, 175),
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
