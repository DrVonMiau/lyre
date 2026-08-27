"""Frozen entry point for the self-contained Lyre.app (PyInstaller).

Registers the compiled GResource bundle from inside the app, then hands off to
the normal application code. The Homebrew-based build uses bootstrap.py for the
same purpose; this variant resolves paths against PyInstaller's _MEIPASS.
"""
import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)

_BASE = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))

if __name__ == "__main__":
    import gi  # noqa: F401
    from gi.repository import Gio

    resource = Gio.Resource.load(os.path.join(_BASE, "lyre.gresource"))
    resource._register()

    from lyre import main

    sys.exit(main.main(os.environ.get("LYRE_VERSION", "")))
