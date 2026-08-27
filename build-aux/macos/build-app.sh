#!/usr/bin/env bash
#
# Build a double-clickable Lyre.app bundle for macOS.
#
# Lyre is a Python + GTK4/libadwaita/GStreamer application. Rather than
# maintain a second codebase, the Mac app reuses the exact same source: this
# script compiles the GResource + GSettings schema, lays out an .app bundle,
# and writes a launcher that points GTK at a Homebrew-provided GTK stack. You
# keep developing on Linux; re-running this script re-packages the Mac app.
#
# Usage:
#   build-aux/macos/build-app.sh [--dmg] [--skip-deps] [--output DIR]
#
#   --dmg         also produce a distributable Lyre-<version>.dmg
#   --skip-deps   don't check/install Homebrew dependencies
#   --output DIR  where to place Lyre.app (default: <project>/dist)
#
# Requirements: macOS 11+ and Homebrew (https://brew.sh). The script installs
# the GTK/GStreamer formulae and IBM Plex font casks it needs unless you pass
# --skip-deps.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUTPUT_DIR="$PROJECT_ROOT/dist"
MAKE_DMG=0
SKIP_DEPS=0

while [ $# -gt 0 ]; do
	case "$1" in
		--dmg) MAKE_DMG=1 ;;
		--skip-deps) SKIP_DEPS=1 ;;
		--output) shift; OUTPUT_DIR="$1" ;;
		-h|--help)
			sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) echo "Unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

# ---------------------------------------------------------------------------
# Pretty logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
	BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; RESET=$'\033[0m'
else
	BLUE=; GREEN=; YELLOW=; RED=; RESET=
fi
step() { echo "${BLUE}==>${RESET} $*"; }
ok()   { echo "${GREEN}  ✓${RESET} $*"; }
warn() { echo "${YELLOW}  !${RESET} $*" >&2; }
die()  { echo "${RED}error:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "Lyre.app can only be built on macOS (this is $(uname -s)). Run this on a Mac."
command -v brew >/dev/null 2>&1 || die "Homebrew is required. Install it from https://brew.sh and re-run."

BREW_PREFIX="$(brew --prefix)"
ok "Homebrew at $BREW_PREFIX"

# Homebrew formulae + font casks the app needs at runtime.
BREW_FORMULAE=(
	python3
	pygobject3
	gtk4
	libadwaita
	gobject-introspection
	librsvg
	adwaita-icon-theme
	gstreamer
)
BREW_CASKS=(
	font-ibm-plex-mono
	font-ibm-plex-sans
)

if [ "$SKIP_DEPS" -eq 0 ]; then
	step "Checking Homebrew dependencies"
	missing=()
	for f in "${BREW_FORMULAE[@]}"; do
		brew list --formula "$f" >/dev/null 2>&1 || missing+=("$f")
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		warn "Installing missing formulae: ${missing[*]}"
		brew install "${missing[@]}"
	fi
	for c in "${BREW_CASKS[@]}"; do
		if ! brew list --cask "$c" >/dev/null 2>&1; then
			warn "Installing font cask: $c"
			brew install --cask "$c" || warn "Could not install $c — Lyre will fall back to system fonts."
		fi
	done
	ok "Dependencies satisfied"
else
	warn "Skipping dependency checks (--skip-deps)"
fi

# Tools we drive below (prefer Homebrew's copies).
GLIB_COMPILE_RESOURCES="$(command -v glib-compile-resources || echo "$BREW_PREFIX/bin/glib-compile-resources")"
GLIB_COMPILE_SCHEMAS="$(command -v glib-compile-schemas || echo "$BREW_PREFIX/bin/glib-compile-schemas")"
PYTHON="$BREW_PREFIX/bin/python3"
[ -x "$GLIB_COMPILE_RESOURCES" ] || die "glib-compile-resources not found (brew install glib)."
[ -x "$GLIB_COMPILE_SCHEMAS" ] || die "glib-compile-schemas not found (brew install glib)."
[ -x "$PYTHON" ] || die "$PYTHON not found (brew install python)."

# ---------------------------------------------------------------------------
# Version (single source of truth: the top-level meson.build)
# ---------------------------------------------------------------------------
VERSION="$(sed -n "s/.*version:[[:space:]]*'\([^']*\)'.*/\1/p" "$PROJECT_ROOT/meson.build" | head -n1)"
[ -n "$VERSION" ] || VERSION="0.0.0"
step "Building Lyre.app version $VERSION"

# ---------------------------------------------------------------------------
# Bundle layout
# ---------------------------------------------------------------------------
APP="$OUTPUT_DIR/Lyre.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES" "$RES/glib-2.0/schemas"

# 1. The Python application (src/ becomes the `lyre` package).
step "Copying application sources"
mkdir -p "$RES/lyre"
for f in __init__ main window library metadata models mpris player widgets; do
	cp "$PROJECT_ROOT/src/$f.py" "$RES/lyre/"
done
cp "$SCRIPT_DIR/bootstrap.py" "$RES/bootstrap.py"
ok "Python sources in place"

# 2. Compile the GResource bundle (window.ui, style.css, icons).
step "Compiling GResource bundle"
"$GLIB_COMPILE_RESOURCES" \
	--sourcedir="$PROJECT_ROOT/src" \
	--target="$RES/lyre.gresource" \
	"$PROJECT_ROOT/src/lyre.gresource.xml"
ok "lyre.gresource"

# 3. Compile the GSettings schema into a private dir the launcher points at.
step "Compiling GSettings schema"
cp "$PROJECT_ROOT/data/io.github.drvonmiau.Lyre.gschema.xml" "$RES/glib-2.0/schemas/"
"$GLIB_COMPILE_SCHEMAS" "$RES/glib-2.0/schemas" >/dev/null
ok "gschemas.compiled"

# 4. Bundle the pure-Python dependencies (mutagen, musicbrainzngs).
step "Installing Python dependencies into the bundle"
"$PYTHON" -m pip install --quiet --upgrade --target "$RES/pysite" \
	--break-system-packages \
	mutagen==1.47.0 musicbrainzngs==0.7.1
ok "mutagen + musicbrainzngs bundled"

# 5. App icon (.icns) from the 512px PNG.
step "Rendering app icon"
SRC_PNG="$PROJECT_ROOT/data/icons/hicolor/512x512/apps/io.github.drvonmiau.Lyre.png"
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "$SRC_PNG" ]; then
	ICONSET="$(mktemp -d)/Lyre.iconset"
	mkdir -p "$ICONSET"
	for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
	            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512"; do
		px="${spec%%:*}"; name="${spec##*:}"
		sips -z "$px" "$px" "$SRC_PNG" --out "$ICONSET/icon_${name}.png" >/dev/null
	done
	# 512x512@2x (1024) — upscaled from the 512 source.
	sips -z 1024 1024 "$SRC_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
	iconutil -c icns "$ICONSET" -o "$RES/Lyre.icns"
	rm -rf "$(dirname "$ICONSET")"
	ok "Lyre.icns"
else
	warn "sips/iconutil or source PNG unavailable — bundling PNG without an .icns"
	cp "$SRC_PNG" "$RES/Lyre.png" 2>/dev/null || true
fi

# 6. Info.plist (substitute the version).
step "Writing Info.plist"
sed "s/@VERSION@/$VERSION/g" "$SCRIPT_DIR/Info.plist.in" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
ok "Info.plist"

# 7. Launcher: sets up the GTK/GStreamer environment, then runs bootstrap.py.
#    The Homebrew prefix is baked in, with a runtime fallback so the bundle
#    still works if Homebrew lives elsewhere on the target Mac.
step "Writing launcher"
cat > "$MACOS/Lyre" <<LAUNCHER
#!/usr/bin/env bash
# Auto-generated by build-aux/macos/build-app.sh — do not edit by hand.
set -e
RES="\$(cd "\$(dirname "\$0")/../Resources" && pwd)"

BREW="$BREW_PREFIX"
if [ ! -d "\$BREW" ]; then
	BREW="\$(brew --prefix 2>/dev/null || true)"
	[ -n "\$BREW" ] || BREW="/opt/homebrew"
fi

export LYRE_VERSION="$VERSION"

# GTK / GObject-Introspection / GStreamer, all from Homebrew.
export DYLD_FALLBACK_LIBRARY_PATH="\$BREW/lib:/usr/local/lib:/usr/lib\${DYLD_FALLBACK_LIBRARY_PATH:+:\$DYLD_FALLBACK_LIBRARY_PATH}"
export GI_TYPELIB_PATH="\$BREW/lib/girepository-1.0\${GI_TYPELIB_PATH:+:\$GI_TYPELIB_PATH}"
export GST_PLUGIN_SYSTEM_PATH="\$BREW/lib/gstreamer-1.0"
export XDG_DATA_DIRS="\$BREW/share:/usr/local/share:/usr/share\${XDG_DATA_DIRS:+:\$XDG_DATA_DIRS}"
export FONTCONFIG_PATH="\$BREW/etc/fonts"

# Lyre's own compiled GSettings schema (added alongside GTK's, not replacing).
export GSETTINGS_SCHEMA_DIR="\$RES/glib-2.0/schemas"

# SVG symbolic icons need librsvg's gdk-pixbuf loader.
loaders="\$(ls "\$BREW"/lib/gdk-pixbuf-2.0/*/loaders.cache 2>/dev/null | head -n1 || true)"
if [ -n "\$loaders" ]; then
	export GDK_PIXBUF_MODULE_FILE="\$loaders"
fi

# Keep the read-only bundle pristine (no stray .pyc files).
export PYTHONDONTWRITEBYTECODE=1

exec "\$BREW/bin/python3" "\$RES/bootstrap.py" "\$@"
LAUNCHER
chmod +x "$MACOS/Lyre"
ok "Contents/MacOS/Lyre"

echo
ok "Built ${GREEN}$APP${RESET}"
echo "     Launch with:  open \"$APP\""

# ---------------------------------------------------------------------------
# Optional .dmg
# ---------------------------------------------------------------------------
if [ "$MAKE_DMG" -eq 1 ]; then
	step "Creating disk image"
	DMG="$OUTPUT_DIR/Lyre-$VERSION.dmg"
	STAGE="$(mktemp -d)"
	cp -R "$APP" "$STAGE/"
	ln -s /Applications "$STAGE/Applications"
	rm -f "$DMG"
	hdiutil create -volname "Lyre" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
	rm -rf "$STAGE"
	ok "Built ${GREEN}$DMG${RESET}"
fi
