# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for a self-contained, redistributable Lyre.app on macOS.
#
# PyInstaller embeds the Python interpreter and rewrites the linked GTK/GStreamer
# libraries to load from inside the bundle. This spec adds the runtime-loaded
# pieces PyInstaller can't infer from imports: gdk-pixbuf loaders, GStreamer
# plugins, GSettings schemas, the Adwaita icon theme and the IBM Plex fonts.
#
# Build it via build-aux/macos/bundle-standalone.sh (don't run pyinstaller by
# hand — the script also regenerates the pixbuf loader cache and signs the app).

import glob
import os
import subprocess

from PyInstaller.utils.hooks import collect_data_files
from PyInstaller.utils.hooks.gi import get_gi_typelibs, get_gi_libdir

SPEC_DIR = os.path.dirname(os.path.abspath(SPECPATH))          # build-aux/macos
PROJECT_ROOT = os.path.abspath(os.path.join(SPEC_DIR, "..", ".."))
SRC = os.path.join(PROJECT_ROOT, "src")

BREW = subprocess.check_output(["brew", "--prefix"], text=True).strip()
LIBDIR = get_gi_libdir()          # usually $BREW/lib
DATADIR = os.path.join(BREW, "share")

binaries = []
datas = []
hiddenimports = ["mutagen", "musicbrainzngs", "gi"]


def add_tree(src_dir, dest_dir):
    """Recursively stage a data directory into the bundle."""
    if not os.path.isdir(src_dir):
        print(f"lyre.spec: warning: {src_dir} not found, skipping")
        return
    for root, _dirs, files in os.walk(src_dir):
        rel = os.path.relpath(root, src_dir)
        for f in files:
            datas.append((os.path.join(root, f), os.path.join(dest_dir, rel)))


# --- GObject-Introspection typelibs + their shared libraries ---------------
GI_MODULES = [
    ("GLib", "2.0"), ("GObject", "2.0"), ("Gio", "2.0"),
    ("Gdk", "4.0"), ("Gtk", "4.0"), ("Adw", "1"),
    ("GdkPixbuf", "2.0"), ("Pango", "1.0"), ("PangoCairo", "1.0"),
    ("cairo", "1.0"), ("HarfBuzz", "0.0"), ("Graphene", "1.0"),
    ("Gst", "1.0"), ("GstAudio", "1.0"), ("GstPbutils", "1.0"), ("GstTag", "1.0"),
]
for mod, ver in GI_MODULES:
    try:
        b, d, h = get_gi_typelibs(mod, ver)
        binaries += b
        datas += d
        hiddenimports += h
    except Exception as exc:  # noqa: BLE001 — a missing optional module shouldn't abort the build
        print(f"lyre.spec: warning: could not collect {mod} {ver}: {exc}")

# --- gdk-pixbuf loaders (SVG symbolic icons via librsvg) -------------------
for so in glob.glob(os.path.join(LIBDIR, "gdk-pixbuf-2.0", "*", "loaders", "*.so")):
    binaries.append((so, "lib/gdk-pixbuf-2.0/2.10.0/loaders"))

# --- GStreamer plugins + the out-of-process plugin scanner -----------------
for dylib in glob.glob(os.path.join(LIBDIR, "gstreamer-1.0", "*.dylib")):
    binaries.append((dylib, "lib/gstreamer-1.0"))
for scanner in glob.glob(os.path.join(BREW, "libexec", "gstreamer-1.0", "gst-plugin-scanner")):
    binaries.append((scanner, "libexec/gstreamer-1.0"))

# --- GIO modules (TLS, needed for the MusicBrainz HTTPS lookups) -----------
for so in glob.glob(os.path.join(LIBDIR, "gio", "modules", "*.so")):
    binaries.append((so, "lib/gio/modules"))

# --- Lyre's own resources --------------------------------------------------
# The bundle script stages everything under build-aux/macos/_staging first:
# the entry point, the `lyre` package (a copy of src/), and the compiled
# GResource / schema / fonts config. The `lyre` package is frozen via pathex
# below; the GResource and data files are added here.
STAGING = os.path.join(SPEC_DIR, "_staging")
datas.append((os.path.join(STAGING, "lyre.gresource"), "."))
add_tree(os.path.join(STAGING, "schemas"), "share/glib-2.0/schemas")

# --- Icon themes (window controls + fallbacks) -----------------------------
add_tree(os.path.join(DATADIR, "icons", "Adwaita"), "share/icons/Adwaita")
add_tree(os.path.join(DATADIR, "icons", "hicolor"), "share/icons/hicolor")

# --- Fonts (IBM Plex) + a fontconfig config that also honours the user's ---
for pattern in ("IBMPlexSans-*.ttf", "IBMPlexMono-*.ttf"):
    for font in glob.glob(os.path.join(os.path.expanduser("~/Library/Fonts"), pattern)):
        datas.append((font, "share/fonts"))
datas.append((os.path.join(STAGING, "fonts.conf"), "etc/fonts"))


block_cipher = None

a = Analysis(
    [os.path.join(STAGING, "entry.py")],
    pathex=[STAGING],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[os.path.join(SPEC_DIR, "pyi-rthook.py")],
    excludes=["tkinter", "PyQt5", "PyQt6", "PySide6"],
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="Lyre",
    debug=False,
    strip=False,
    upx=False,
    console=False,
)
coll = COLLECT(
    exe, a.binaries, a.zipfiles, a.datas,
    strip=False, upx=False, name="Lyre",
)
app = BUNDLE(
    coll,
    name="Lyre.app",
    icon=os.path.join(STAGING, "Lyre.icns"),
    bundle_identifier="io.github.drvonmiau.Lyre",
    info_plist={
        "CFBundleName": "Lyre",
        "CFBundleDisplayName": "Lyre",
        "CFBundleShortVersionString": os.environ.get("LYRE_VERSION", "0.0.0"),
        "CFBundleVersion": os.environ.get("LYRE_VERSION", "0.0.0"),
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "11.0",
        "LSApplicationCategoryType": "public.app-category.music",
        "NSHumanReadableCopyright": "© 2026 Daniel. GNU GPL v3 or later.",
    },
)
