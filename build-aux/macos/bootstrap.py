"""macOS launch entry point for Lyre (analogue of src/lyre.in).

The .app's executable is a shell launcher (Contents/MacOS/Lyre) that sets up
the GTK/GStreamer environment from Homebrew and then runs this file with
Homebrew's python3. Here we register the compiled GResource bundle and hand
off to the normal application code, exactly as the Flatpak/Meson entry point
does on Linux.
"""
import os
import signal
import sys

# This file lives at Lyre.app/Contents/Resources/bootstrap.py.
RES = os.path.dirname(os.path.abspath(__file__))

# The Python package (the src/ tree, installed as `lyre`) and the pure-Python
# dependencies (mutagen, musicbrainzngs) bundled beside it.
sys.path.insert(0, RES)
sys.path.insert(0, os.path.join(RES, "pysite"))

signal.signal(signal.SIGINT, signal.SIG_DFL)

if __name__ == "__main__":
    import gi  # noqa: F401  (ensures PyGObject is importable before we use it)
    from gi.repository import Gio

    resource = Gio.Resource.load(os.path.join(RES, "lyre.gresource"))
    resource._register()

    from lyre import main

    sys.exit(main.main(os.environ.get("LYRE_VERSION", "")))
