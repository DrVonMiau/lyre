# Building Lyre for macOS

Lyre is a Python + GTK4 / libadwaita / GStreamer application. On macOS it runs
as a `Lyre.app` bundle built from the **same source** as the Linux/Flatpak
build — there is deliberately no second, native codebase to keep in sync.
`build-app.sh` reuses `src/` as-is, so anything you change on Linux flows into
the Mac app the next time you run the script.

## How it works

The GTK stack itself (GTK4, libadwaita, GStreamer, PyGObject, librsvg, the
Adwaita icon theme) is provided by [Homebrew](https://brew.sh). The bundle is
a thin wrapper around it:

```
Lyre.app/
└── Contents/
    ├── Info.plist              # from Info.plist.in, version substituted
    ├── MacOS/Lyre              # launcher: sets up the GTK env, runs bootstrap.py
    └── Resources/
        ├── bootstrap.py        # registers the GResource, calls lyre.main
        ├── lyre/               # the src/ Python package, copied verbatim
        ├── lyre.gresource      # compiled window.ui + style.css + icons
        ├── glib-2.0/schemas/   # compiled GSettings schema (gschemas.compiled)
        ├── pysite/             # bundled mutagen + musicbrainzngs
        └── Lyre.icns           # app icon, rendered from the 512px PNG
```

`Contents/MacOS/Lyre` bakes in the Homebrew prefix (with a runtime fallback to
`brew --prefix` / `/opt/homebrew`) and exports the environment GTK needs —
`GI_TYPELIB_PATH`, `GST_PLUGIN_SYSTEM_PATH`, `GDK_PIXBUF_MODULE_FILE`,
`XDG_DATA_DIRS`, `GSETTINGS_SCHEMA_DIR` and friends — before running the app
with Homebrew's `python3`.

This keeps maintenance low: no dylib relocation, no jhbuild, no vendored GTK.
The trade-off is that the resulting `.app` expects Homebrew and its GTK
formulae to be present on the machine that runs it (fine for your own Macs and
for developer distribution). A fully self-contained, notarizable bundle would
need the libraries copied in and code-signed — a possible future step, not
required to run.

## Requirements

- macOS 11 (Big Sur) or newer
- [Homebrew](https://brew.sh)

The script installs the formulae and font casks it needs automatically:

- **Formulae:** `python3`, `pygobject3`, `gtk4`, `libadwaita`,
  `gobject-introspection`, `librsvg`, `adwaita-icon-theme`, `gstreamer`
- **Casks (fonts):** `font-ibm-plex-mono`, `font-ibm-plex-sans` — the
  typefaces the UI is designed around; without them Lyre falls back to the
  system sans/mono.

## Usage

```sh
# From the repository root:
build-aux/macos/build-app.sh
open dist/Lyre.app
```

Options:

| Flag           | Effect                                                       |
| -------------- | ------------------------------------------------------------ |
| `--dmg`        | also build `dist/Lyre-<version>.dmg` for distribution        |
| `--skip-deps`  | skip the Homebrew dependency check/install (build faster)    |
| `--output DIR` | write `Lyre.app` somewhere other than `dist/`                |

The app version is read from the top-level `meson.build`, so it stays in step
with the Linux release.

## Troubleshooting

- **`No module named 'gi'` / typelib errors on launch.** PyGObject and the GTK
  formulae must belong to the same Homebrew `python3`. If you upgraded Python,
  run `brew reinstall pygobject3 gtk4 libadwaita gstreamer` and rebuild.

- **Fonts look wrong.** Install the Plex casks:
  `brew install --cask font-ibm-plex-mono font-ibm-plex-sans`, then relaunch.

- **Symbolic icons (play/pause, volume) are missing.** These render via
  librsvg's gdk-pixbuf loader; make sure `librsvg` is installed and rebuild so
  the launcher's `GDK_PIXBUF_MODULE_FILE` points at a fresh `loaders.cache`.

- **Media keys / the macOS Now Playing widget don't control Lyre.** That's
  expected: those rely on MPRIS (a Linux D-Bus service), which is skipped on
  macOS. In-app and on-screen controls work normally.

- **Debugging.** Run the launcher from a terminal to see GTK's output:
  `dist/Lyre.app/Contents/MacOS/Lyre`.
