#!/usr/bin/env bash
#
# Build a SELF-CONTAINED, redistributable Lyre.app + .dmg for macOS.
#
# Unlike build-app.sh (which wires the app to a Homebrew GTK install), this
# embeds the entire Python + GTK4/libadwaita/GStreamer stack inside the bundle
# via PyInstaller, so the resulting .app runs on any Mac with NO Homebrew.
# The bundle is ad-hoc code-signed (required for Apple Silicon to run it at
# all); it is NOT notarized, so on first launch users right-click -> Open once
# to get past Gatekeeper. See build-aux/macos/README.md.
#
# You still BUILD it on a Mac that has Homebrew + the GTK formulae — Homebrew is
# only the source of the libraries that get copied in.
#
# Usage: build-aux/macos/bundle-standalone.sh [--skip-deps] [--no-dmg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGING="$SCRIPT_DIR/_staging"
DIST="$PROJECT_ROOT/dist"
BUILD="$PROJECT_ROOT/build/pyi"
VENV="$PROJECT_ROOT/build/pyi-venv"

SKIP_DEPS=0
MAKE_DMG=1
while [ $# -gt 0 ]; do
	case "$1" in
		--skip-deps) SKIP_DEPS=1 ;;
		--no-dmg) MAKE_DMG=0 ;;
		-h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

if [ -t 1 ]; then
	BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; RESET=$'\033[0m'
else
	BLUE=; GREEN=; YELLOW=; RED=; RESET=
fi
step() { echo "${BLUE}==>${RESET} $*"; }
ok()   { echo "${GREEN}  ✓${RESET} $*"; }
warn() { echo "${YELLOW}  !${RESET} $*" >&2; }
die()  { echo "${RED}error:${RESET} $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "This bundler must run on macOS (this is $(uname -s))."
command -v brew >/dev/null 2>&1 || die "Homebrew is required to source the GTK libraries. See https://brew.sh."
BREW_PREFIX="$(brew --prefix)"

BREW_FORMULAE=(python3 pygobject3 gtk4 libadwaita gobject-introspection librsvg adwaita-icon-theme gstreamer)
BREW_CASKS=(font-ibm-plex-mono font-ibm-plex-sans)
if [ "$SKIP_DEPS" -eq 0 ]; then
	step "Checking Homebrew dependencies"
	missing=()
	for f in "${BREW_FORMULAE[@]}"; do brew list --formula "$f" >/dev/null 2>&1 || missing+=("$f"); done
	[ "${#missing[@]}" -gt 0 ] && { warn "Installing: ${missing[*]}"; brew install "${missing[@]}"; }
	for c in "${BREW_CASKS[@]}"; do
		brew list --cask "$c" >/dev/null 2>&1 || brew install --cask "$c" || warn "Could not install $c"
	done
	ok "Dependencies satisfied"
fi

PYTHON="$BREW_PREFIX/bin/python3"
GLIB_COMPILE_RESOURCES="$BREW_PREFIX/bin/glib-compile-resources"
GLIB_COMPILE_SCHEMAS="$BREW_PREFIX/bin/glib-compile-schemas"
QUERY_LOADERS="$(command -v gdk-pixbuf-query-loaders || echo "$BREW_PREFIX/bin/gdk-pixbuf-query-loaders")"
for tool in "$PYTHON" "$GLIB_COMPILE_RESOURCES" "$GLIB_COMPILE_SCHEMAS"; do
	[ -x "$tool" ] || die "Missing tool: $tool"
done

VERSION="$(sed -n "s/.*version:[[:space:]]*'\([^']*\)'.*/\1/p" "$PROJECT_ROOT/meson.build" | head -n1)"
[ -n "$VERSION" ] || VERSION="0.0.0"
export LYRE_VERSION="$VERSION"

# ---------------------------------------------------------------------------
# Python build environment (isolated, but able to see Homebrew's PyGObject).
# ---------------------------------------------------------------------------
step "Setting up the build virtualenv"
rm -rf "$VENV"
"$PYTHON" -m venv --system-site-packages "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -c "import gi" 2>/dev/null || die "PyGObject (gi) not importable — run: brew reinstall pygobject3"
pip install --quiet --upgrade pip
pip install --quiet "pyinstaller>=6.0" pyinstaller-hooks-contrib mutagen==1.47.0 musicbrainzngs==0.7.1
ok "virtualenv ready ($(python --version 2>&1))"

# ---------------------------------------------------------------------------
# Stage Lyre's own resources for the spec to pick up.
# ---------------------------------------------------------------------------
step "Staging application resources (version $VERSION)"
rm -rf "$STAGING"
mkdir -p "$STAGING/lyre" "$STAGING/schemas"

# The `lyre` package (a copy of src/).
for f in __init__ main window library metadata models mpris player widgets; do
	cp "$PROJECT_ROOT/src/$f.py" "$STAGING/lyre/"
done
cp "$SCRIPT_DIR/entry.py" "$STAGING/entry.py"

# Compiled GResource.
"$GLIB_COMPILE_RESOURCES" \
	--sourcedir="$PROJECT_ROOT/src" \
	--target="$STAGING/lyre.gresource" \
	"$PROJECT_ROOT/src/lyre.gresource.xml"

# GSettings schemas: GTK's own + Lyre's, compiled into one dir so the bundled
# app finds every schema it references without a system GLib.
cp "$BREW_PREFIX"/share/glib-2.0/schemas/*.gschema.xml "$STAGING/schemas/" 2>/dev/null || true
cp "$BREW_PREFIX"/share/glib-2.0/schemas/*.enums.xml "$STAGING/schemas/" 2>/dev/null || true
cp "$PROJECT_ROOT/data/io.github.drvonmiau.Lyre.gschema.xml" "$STAGING/schemas/"
"$GLIB_COMPILE_SCHEMAS" "$STAGING/schemas" >/dev/null

# Fontconfig config: bundled IBM Plex first, then the user's/system fonts.
cat > "$STAGING/fonts.conf" <<'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir prefix="relative">../../share/fonts</dir>
  <dir>~/Library/Fonts</dir>
  <dir>/Library/Fonts</dir>
  <dir>/System/Library/Fonts</dir>
  <cachedir>~/.cache/io.github.drvonmiau.Lyre/fontconfig</cachedir>
  <config></config>
</fontconfig>
FONTCONF

# App icon (.icns) from the 512px PNG.
SRC_PNG="$PROJECT_ROOT/data/icons/hicolor/512x512/apps/io.github.drvonmiau.Lyre.png"
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "$SRC_PNG" ]; then
	ICONSET="$STAGING/Lyre.iconset"; mkdir -p "$ICONSET"
	for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
	            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512"; do
		sips -z "${spec%%:*}" "${spec%%:*}" "$SRC_PNG" --out "$ICONSET/icon_${spec##*:}.png" >/dev/null
	done
	sips -z 1024 1024 "$SRC_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
	iconutil -c icns "$ICONSET" -o "$STAGING/Lyre.icns"
	rm -rf "$ICONSET"
else
	warn "Could not render .icns (sips/iconutil missing); the app will use a default icon"
	: > "$STAGING/Lyre.icns" || true
fi
ok "Resources staged"

# ---------------------------------------------------------------------------
# Freeze the bundle.
# ---------------------------------------------------------------------------
step "Running PyInstaller (this takes a few minutes)"
rm -rf "$DIST/Lyre.app" "$BUILD"
pyinstaller --noconfirm --clean \
	--distpath "$DIST" --workpath "$BUILD" \
	"$SCRIPT_DIR/lyre.spec"
APP="$DIST/Lyre.app"
[ -d "$APP" ] || die "PyInstaller did not produce $APP"
ok "Froze $APP"

# ---------------------------------------------------------------------------
# Regenerate the gdk-pixbuf loader cache with bundle-relative module paths.
# ---------------------------------------------------------------------------
step "Rebuilding the gdk-pixbuf loader cache"
LOADERS_ROOT="$APP/Contents/Frameworks/lib/gdk-pixbuf-2.0/2.10.0"
if [ -d "$LOADERS_ROOT/loaders" ] && [ -x "$QUERY_LOADERS" ]; then
	( cd "$LOADERS_ROOT/loaders" && "$QUERY_LOADERS" ./*.so ) > "$LOADERS_ROOT/loaders.cache"
	ok "loaders.cache ($(grep -c '\.so' "$LOADERS_ROOT/loaders.cache" 2>/dev/null || echo 0) loaders)"
else
	warn "No bundled pixbuf loaders found — SVG icons may not render"
fi

# ---------------------------------------------------------------------------
# Ad-hoc code signature (mandatory on Apple Silicon, even unsigned).
# ---------------------------------------------------------------------------
step "Ad-hoc signing the bundle"
codesign --force --deep --sign - "$APP" 2>/dev/null && ok "Signed (ad-hoc)" \
	|| warn "codesign failed; on Apple Silicon the app may refuse to launch"

echo
ok "Built ${GREEN}$APP${RESET}"

# ---------------------------------------------------------------------------
# Package a drag-to-install .dmg.
# ---------------------------------------------------------------------------
if [ "$MAKE_DMG" -eq 1 ]; then
	step "Building disk image"
	DMG="$DIST/Lyre-$VERSION.dmg"
	STAGE="$(mktemp -d)"
	cp -R "$APP" "$STAGE/"
	ln -s /Applications "$STAGE/Applications"
	rm -f "$DMG"
	hdiutil create -volname "Lyre $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
	rm -rf "$STAGE"
	ok "Built ${GREEN}$DMG${RESET}"
	echo
	echo "  Share $DMG. Users drag Lyre to Applications, then on first launch"
	echo "  right-click Lyre.app -> Open (once) to get past Gatekeeper."
fi

deactivate 2>/dev/null || true
