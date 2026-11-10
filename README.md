# MacPaperEngine

Desktop wallpapers for macOS, built to use as little memory as possible.

Three kinds, each with its own tab:

- **Videos**: six abstract loops built in, plus your own videos and GIFs. Loops restart without a
  visible jump.
- **Dynamic**: pictures that change with the sun or with Light and Dark mode, like macOS's own.
  Five come with MacPaperEngine (Alps, Fuji, Cyprus, Dome, Fletschhorn), and you can add your own
  `.heic` files.
- **Pictures**: still images, drawn once and costing no power while shown.

The built-in clips and dynamic wallpapers aren't inside the app, which is about 7 MB. Each one
downloads from [macpaper-media](https://github.com/edisadk-pm/macpaper-media/releases) the first
time you pick it (60 to 240 MB for a clip), then stays on your Mac.

**Online** browses Wallhaven for pictures and Pexels for videos, and downloads and applies one in
a click. Wallpapers show behind your desktop icons and on the Lock Screen. On the desktop MacPaperEngine
draws above your system wallpaper, which reappears when it stops.

## Install

Download `MacPaperEngine.zip` from the
[latest release](https://github.com/edisadk-pm/MacPaperEngine/releases/latest), unzip it and move
`MacPaperEngine.app` to `/Applications`. Do this before turning on **Start Wallpaper at Login**,
because the login item points at the app's current location.

The app isn't notarized, so the first time macOS says it can't check it. Open **System Settings >
Privacy & Security** and click **Open Anyway** next to MacPaperEngine. Only that first launch asks.

## Updates

MacPaperEngine updates itself from this repository's
[releases](https://github.com/edisadk-pm/MacPaperEngine/releases). The first time you open it, a
sheet says so and asks how far it should go:

| Choice | Does |
| --- | --- |
| **Automatic** (recommended) | Checks each time you open the window, downloads a new version in the background, and installs it when you close the window |
| **Ask First** | Checks each time you open the window, and asks before downloading |
| **Manual** | Looks only when you choose **MacPaperEngine > Check for Updates…** |

You can change it later in **General > Updates**. Before a download is kept, it's checked against
the SHA-256 checksum published with the release, the app's bundle identifier, the version and the
code signature. When it's ready, the sidebar says so and offers **Restart Now**; otherwise it's
swapped in when you close the window, and the wallpaper is back within a second or two. The next
time you open the app, the sidebar says what's new.

Only copies in an `Applications` folder update. A build run from `build/`, or against a test library
with `MACPAPER_HOME`, never does, unless `MACPAPER_UPDATE_FEED` points it at a test feed. Its update
settings are then kept apart from the installed app's.

## Build and run

Requires macOS 14 or later and Xcode.

```sh
./build.sh
open build/MacPaperEngine.app
```

### Releasing

```sh
Packaging/release.sh 1.2.0 "What changed"
```

The working tree must be clean. The script sets the version in both `Info.plist`s, builds, zips
`MacPaperEngine.app` with its checksum, commits "Release 1.2.0", tags `v1.2.0`, pushes and creates
the GitHub release. Installed copies pick it up within six hours.

### Built-in media

The full clips and dynamic wallpapers live in `Media/`, which git ignores, and in the
`media-1` release of [macpaper-media](https://github.com/edisadk-pm/macpaper-media). The app ships
only `Resources/*/catalog.json` and small previews. After changing `Media/`:

```sh
Packaging/make-previews.sh      # previews and file sizes for the catalogs
gh release upload media-1 Media/Footage/*.mp4 Media/Dynamic/*.heic \
    --repo edisadk-pm/macpaper-media --clobber
```

`MACPAPER_MEDIA_URL=file:///path/to/folder/` makes a development build download from a local
folder instead.

## Using the app

The window works like System Settings: a sidebar you can hide (⌃⌘S), Back and Forward in the
toolbar, and each page's actions next to its title. Add sits in the toolbar on the library tabs,
and Online puts its Pictures/Videos switch and search there. The window has a fixed width and can
be made taller.

| Shortcut | Does |
| --- | --- |
| ⌘1 to ⌘9 | Videos, Dynamic, Pictures, Online, Displays, Playback, Power, General, Stats |
| ⌘[ and ⌘] | Back and Forward |
| ⌘O | Add wallpapers to the tab you're on |
| ⌘F | Search online |
| ⌥⌘P | Pause or resume the wallpaper (also in the toolbar and the menu bar icon) |
| ⌥⌘→ and ⌥⌘← | Next and previous wallpaper in the current one's tab |
| ⌘, | Settings |
| ⌥⌘Q | Quit and stop the wallpaper too. Plain ⌘Q leaves the wallpaper running. |

The **Wallpaper** menu also turns the wallpaper off, jumps to the one showing, removes it, and
switches Play on Lock Screen and Hide Loop Jump.

## Adding wallpapers

Click **Add** on any library tab, drop files anywhere in the window, or drag them onto the Dock
icon. Each file goes to the tab it belongs in:

| File | Tab |
| --- | --- |
| MP4, MOV, M4V | Videos |
| GIF, animated WebP, APNG | Videos, converted to video on import |
| HEIC with time-of-day or Light/Dark pictures | Dynamic |
| JPEG, PNG, HEIC and other still images | Pictures |

To remove something you added or downloaded, hover over it and click the **×** in its corner, or
right-click it. MacPaperEngine asks first, and deletes only its own copy: the file you added from your
Mac stays where it was. Built-ins can't be removed, but right-clicking one offers **Remove
Download** to free its space, and **General > Downloaded Built-ins > Remove Unused** clears every
one that isn't on screen. They download again when picked.

**Hide Loop Jump** (Playback, on by default) makes a copy of each of your videos whose first
half-second blends in its last, so the restart can't be seen. The copy is made once, in the
background while the window is open, and playback costs nothing extra. Built-in clips already loop
cleanly.

Dynamic wallpapers that follow the sun judge its position from your time zone's reference city in
`/usr/share/zoneinfo/zone.tab`, so no location access is needed. Files that only describe sunrise
run the same pictures in reverse at sunset, and two-picture day-and-night files switch at sunrise
and sunset whatever hours they were saved with.

## Online

- **Pictures** come from [Wallhaven](https://wallhaven.cc), with no account needed. Only images
  marked safe for work are requested. They're uploaded by Wallhaven's community under mixed
  licences, so check one before sharing it.
- **Videos** come from [Pexels](https://www.pexels.com). Pexels needs a free API key: the Online
  page walks you through getting one and keeps it on your Mac. The file downloaded is the one that
  best matches your display, never larger, because a 4K file costs twice the memory to play.

Only the window process goes online, for browsing, built-in downloads and updates. The engine
never does.

## Lock Screen

macOS draws the Lock Screen itself and hides every app's windows there, so a desktop app can't
appear on it. **Displays > Play on Lock Screen** registers your video as an Aerial in your own
`~/Library/Application Support/com.apple.wallpaper` folder, and macOS plays it from there.
Pictures and dynamic wallpapers need no conversion: they become the system wallpaper directly. No
admin rights are needed.

This changes your system wallpaper while it's on. Turning it off restores your previous choice,
which is kept in `SystemWallpaperBackup.plist` in the app's data folder
(`~/Library/Application Support/MacPaper`).

It isn't a public API. macOS refreshes its Aerial list periodically, which MacPaperEngine detects and
repairs, but a major macOS update could break it.

## Why it uses so little memory

Two processes, so that the interface costs nothing when you aren't looking at it:

| Process | Runs | Built with |
| --- | --- | --- |
| `MacPaperEngine Helper` | Always, with the wallpaper | AppKit, AVFoundation |
| `MacPaperEngine` | Only while the window is open | SwiftUI |

They share `~/Library/Application Support/MacPaper/state.json` and signal each other with
distributed notifications.

- **Video** is read as compressed samples and fed to a hardware decoder only a few frames ahead of
  the playhead, growing that window only if frames actually drop (`VideoContent.swift`). Decoded
  frames are nearly all of a video's memory cost.
- **Animated images** become video on import, so frames are never all held in memory.
- **Pictures and dynamic wallpapers** are decoded once at the screen's size, so a 6K original
  never sits in memory, and nothing runs until the next picture is due (`StillContent.swift`).
- **Playback stops** when windows cover the desktop, the screen locks or sleeps, in Low Power Mode,
  and optionally on battery (`PowerMonitor.swift`).

Measured on an M2 MacBook Air, engine plus macOS's decoder helper, while playing:

| Wallpaper | MacPaperEngine | `AVPlayerLooper`, for comparison |
| --- | --- | --- |
| 2560×1664 HEVC, 30 fps | about 80 MB | 112 MB |
| 3840×2160 HEVC, 60 fps | about 160 MB | 278 MB |
| Picture or dynamic wallpaper | about 37 to 49 MB | n/a |

macOS decodes video in a separate process, which Activity Monitor lists as `VTDecoderXPCService`.
Count it when comparing. The Stats page in the app includes it.
