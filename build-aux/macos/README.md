# Building Lyre for macOS

Lyre is a Python + GTK4 / libadwaita / GStreamer application. On macOS it runs
as a `Lyre.app` bundle built from the **same source** as the Linux/Flatpak
build — there is deliberately no second, native codebase to keep in sync. The
build scripts reuse `src/` as-is, so anything you change on Linux flows into the
Mac app the next time you build.

There are two builds, for two different audiences:

| Script                 | Output                          | Runs on a Mac that has… | Use it for            |
| ---------------------- | ------------------------------- | ----------------------- | --------------------- |
| `build-app.sh`         | `dist/Lyre.app` (Homebrew-wired) | Homebrew + the GTK deps | your own dev machine  |
| `bundle-standalone.sh` | `dist/Lyre-<v>.dmg` (self-contained) | nothing (any Mac)  | giving it to people   |

Both are described below. If you just want to hand someone a file they can run,
you want **`bundle-standalone.sh`**.

## The Homebrew build (`build-app.sh`)

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
formulae to be present on the machine that runs it — which is why it's the
*developer* build. For a copy other people can run, use the standalone build
below.

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

## The standalone build (`bundle-standalone.sh`)

This produces a `Lyre.app` (and a drag-to-install `.dmg`) with the **entire**
Python + GTK4 / libadwaita / GStreamer stack embedded, so it runs on any Mac
with no Homebrew. You still build it on a Mac that *has* Homebrew and the GTK
formulae — Homebrew is only the source of the libraries that get copied in.

```sh
build-aux/macos/bundle-standalone.sh    # -> dist/Lyre-<version>.dmg
```

Under the hood it uses [PyInstaller](https://pyinstaller.org): it embeds the
Python interpreter and rewrites the linked libraries to load from inside the
bundle, and `lyre.spec` + `pyi-rthook.py` add the runtime-loaded pieces
PyInstaller can't infer — the gdk-pixbuf loaders, GStreamer plugins, GSettings
schemas, the Adwaita icon theme and the IBM Plex fonts. The bundle is **ad-hoc
signed** (Apple Silicon refuses to launch an unsigned binary) but **not
notarized**, because that needs a paid Apple Developer account.

Flags: `--skip-deps` (skip the Homebrew check), `--no-dmg` (just the `.app`).

### Installing it (what your users do)

1. Open the `.dmg` and drag **Lyre** to **Applications**.
2. First launch only: right-click (or Control-click) `Lyre.app` → **Open** →
   **Open** in the dialog. macOS remembers the choice; after that it's a normal
   double-click.

   The right-click step is the Gatekeeper toll for an app that isn't notarized.
   The alternative, if you'd rather script it, is to clear the quarantine flag:
   `xattr -dr com.apple.quarantine /Applications/Lyre.app`.

## About the window chrome

Lyre uses GTK4/libadwaita, which draws its **own** window header bar and
controls (client-side decorations) rather than a native Cocoa title bar. On
macOS the window buttons are moved to the left and restyled into red/amber/green
**traffic-light buttons** (the `.macos` rules in `src/style.css`, applied when
the app detects macOS), with the close/minimise/maximise glyphs surfacing on
hover — so the window reads as a Mac window at a glance.

This is a close cosmetic approximation, not true native chrome: the buttons are
still GTK-drawn, so on close inspection they won't be pixel-identical to Cocoa's
and the surrounding header bar is still libadwaita's. Getting *genuinely* native
chrome (real Cocoa traffic lights and a unified titlebar) isn't possible from
GTK — it would require a native (e.g. SwiftUI/AppKit) UI, i.e. a second
codebase. The traffic-light styling is the pragmatic middle ground that keeps
one codebase.

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
