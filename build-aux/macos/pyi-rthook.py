"""PyInstaller runtime hook for the self-contained Lyre.app.

PyInstaller's own GObject-introspection hook already points GI_TYPELIB_PATH and
the GObject module paths at the bundled copies. This hook fills in the pieces it
does not know about — the things GTK/GStreamer load at runtime by path rather
than by linking — so the app finds them inside the bundle instead of looking
for a Homebrew install that isn't there.

Everything is resolved relative to sys._MEIPASS (Lyre.app/Contents/Frameworks),
which is where the spec's `binaries`/`datas` land.
"""
import os
import sys

_BASE = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))


def _set_default(name, value):
    if value and os.path.exists(value):
        os.environ[name] = value


# GStreamer: plugins (codecs, playbin) + the out-of-process plugin scanner.
_gst = os.path.join(_BASE, "lib", "gstreamer-1.0")
_set_default("GST_PLUGIN_PATH", _gst)
_set_default("GST_PLUGIN_SYSTEM_PATH", _gst)
os.environ.setdefault("GST_PLUGIN_PATH_1_0", _gst)
_set_default(
    "GST_PLUGIN_SCANNER",
    os.path.join(_BASE, "libexec", "gstreamer-1.0", "gst-plugin-scanner"),
)
# Ignore any user registry so a stale one on the machine can't hide our plugins.
os.environ.setdefault("GST_REGISTRY_UPDATE", "yes")

# gdk-pixbuf loaders (SVG symbolic icons render via librsvg's loader).
_pixbuf = os.path.join(_BASE, "lib", "gdk-pixbuf-2.0", "2.10.0")
_set_default("GDK_PIXBUF_MODULEDIR", os.path.join(_pixbuf, "loaders"))
_set_default("GDK_PIXBUF_MODULE_FILE", os.path.join(_pixbuf, "loaders.cache"))

# GSettings schemas (GTK's own + Lyre's, compiled together at build time).
_set_default("GSETTINGS_SCHEMA_DIR", os.path.join(_BASE, "share", "glib-2.0", "schemas"))

# Icon themes (Adwaita/hicolor) live under the bundled data dir.
_share = os.path.join(_BASE, "share")
if os.path.isdir(_share):
    existing = os.environ.get("XDG_DATA_DIRS", "")
    os.environ["XDG_DATA_DIRS"] = _share + (os.pathsep + existing if existing else "")

# Fontconfig: our bundled config points at the bundled IBM Plex fonts and the
# user's own font dirs, so the UI matches the Linux build.
_fc = os.path.join(_BASE, "etc", "fonts", "fonts.conf")
_set_default("FONTCONFIG_FILE", _fc)
_set_default("FONTCONFIG_PATH", os.path.join(_BASE, "etc", "fonts"))
