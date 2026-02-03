#!/bin/bash
set -e

# Setup directories
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$ROOT_DIR/work"
EXTRACTED_DIR="$WORK_DIR/extracted"
APP_DIR="$WORK_DIR/app"
NATIVE_BUILD_DIR="$WORK_DIR/native-builds"
DIST_DIR="$ROOT_DIR/dist"

# Config
DMG_PATH="${1:-$ROOT_DIR/Codex.dmg}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check dependencies
check_dep() {
    if ! command -v "$1" &> /dev/null; then
        err "$1 could not be found. Please install it."
        if [ "$1" == "7z" ]; then
             warn "On Debian/Ubuntu: sudo apt install p7zip-full"
             warn "On Fedora: sudo dnf install p7zip"
             warn "On Arch: sudo pacman -S p7zip"
        fi
        exit 1
    fi
}

check_dep node
check_dep npm
check_dep 7z

if [ ! -f "$DMG_PATH" ]; then
    err "DMG not found at $DMG_PATH"
    warn "Please place Codex.dmg in the root of the repo or pass the path as an argument."
    exit 1
fi

log "Using DMG: $DMG_PATH"

mkdir -p "$WORK_DIR"

# ---------------------------
# Extract DMG (ignore macOS DMG /Applications symlink)
# ---------------------------
if [ ! -d "$EXTRACTED_DIR" ]; then
    log "Extracting DMG..."
    mkdir -p "$EXTRACTED_DIR"

    # Some DMGs contain a symlink like "Applications -> /Applications".
    # Newer 7z treats that as "Dangerous link path..." and returns non-zero.
    # -snld allows extracting those links; we also treat that specific message as a warning.
    set +e
    ERR_LOG="$(mktemp)"
    7z x "$DMG_PATH" -o"$EXTRACTED_DIR" -y -snld > /dev/null 2>"$ERR_LOG"
    RC=$?
    set -e

    if [ $RC -ne 0 ]; then
        if grep -q "Dangerous link path was ignored" "$ERR_LOG"; then
            warn "7z ignored DMG Applications symlink (expected). Continuing."
        else
            cat "$ERR_LOG" >&2
            err "7z extraction failed with exit code $RC"
            exit $RC
        fi
    fi
    rm -f "$ERR_LOG"
else
    log "DMG already extracted. Skipping."
fi

# ---------------------------
# Extract ASAR
# ---------------------------
if [ ! -d "$APP_DIR" ]; then
    log "Extracting app.asar..."
    mkdir -p "$APP_DIR"

    # Try to find app.asar. It might be in different places depending on DMG structure
    ASAR_PATH=$(find "$EXTRACTED_DIR" -name "app.asar" | head -n 1)

    if [ -z "$ASAR_PATH" ]; then
        # Check for HFS
        HFS_PATH=$(find "$EXTRACTED_DIR" -name "*.hfs" | head -n 1)
        if [ -n "$HFS_PATH" ]; then
            log "Found HFS image. Extracting..."
            7z x "$HFS_PATH" -o"$EXTRACTED_DIR/hfs" -y -snld > /dev/null
            ASAR_PATH=$(find "$EXTRACTED_DIR/hfs" -name "app.asar" | head -n 1)
        fi
    fi

    if [ -z "$ASAR_PATH" ]; then
        err "app.asar not found!"
        exit 1
    fi

    log "Found app.asar at $ASAR_PATH"
    npx --yes @electron/asar extract "$ASAR_PATH" "$APP_DIR"

    # Sync app.asar.unpacked if exists
    ASAR_UNPACKED="${ASAR_PATH}.unpacked"
    if [ -d "$ASAR_UNPACKED" ]; then
        log "Syncing app.asar.unpacked..."
        cp -r "$ASAR_UNPACKED/"* "$APP_DIR/"
    fi
else
    log "App already extracted. Skipping."
fi

# ---------------------------
# Read package.json + fix invalid version for electron-builder (must be SemVer)
# ---------------------------
PKG_JSON="$APP_DIR/package.json"

PKG_VERSION="$(node -p "require('$PKG_JSON').version || ''")"
if [ -z "$PKG_VERSION" ]; then
    warn "package.json has no version field; setting to 0.0.0"
    FIXED_VERSION="0.0.0"
else
    # Accept strict-ish semver: X.Y.Z (with optional -pre +build)
    if [[ "$PKG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-][0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?$ ]]; then
        FIXED_VERSION="$PKG_VERSION"
    else
        # Special case seen: "260202.0859" (date.time). This fails because 0859 has a leading zero.
        if [[ "$PKG_VERSION" =~ ^([0-9]{6})\.([0-9]{4})$ ]]; then
            MAJOR="${BASH_REMATCH[1]}"
            # 10# removes leading zeros safely
            MINOR=$((10#${BASH_REMATCH[2]}))
            FIXED_VERSION="${MAJOR}.${MINOR}.0"
        else
            # Fallback: embed original version as build metadata on 0.0.0
            SAFE_META="$(echo "$PKG_VERSION" | sed -E 's/[^0-9A-Za-z-]+/./g; s/^\.+//; s/\.+$//')"
            [ -z "$SAFE_META" ] && SAFE_META="unknown"
            FIXED_VERSION="0.0.0+${SAFE_META}"
        fi

        warn "Invalid version in package.json: \"$PKG_VERSION\" -> using \"$FIXED_VERSION\" for electron-builder"
        node - <<NODE
const fs = require("fs");
const p = "$PKG_JSON";
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.version = "$FIXED_VERSION";
fs.writeFileSync(p, JSON.stringify(j, null, 2));
NODE
    fi
fi

# Extract dependency versions (strip leading non-digits like ^ ~ >=)
ELECTRON_VERSION_RAW=$(node -p "require('$PKG_JSON').devDependencies.electron")
BETTER_SQLITE3_VERSION_RAW=$(node -p "require('$PKG_JSON').dependencies['better-sqlite3']")
NODE_PTY_VERSION_RAW=$(node -p "require('$PKG_JSON').dependencies['node-pty']")

ELECTRON_VERSION=$(node -p "('${ELECTRON_VERSION_RAW}').replace(/^[^0-9]*/, '')")
BETTER_SQLITE3_VERSION=$(node -p "('${BETTER_SQLITE3_VERSION_RAW}').replace(/^[^0-9]*/, '')")
NODE_PTY_VERSION=$(node -p "('${NODE_PTY_VERSION_RAW}').replace(/^[^0-9]*/, '')")

log "App Version (fixed): $FIXED_VERSION"
log "Electron Version: $ELECTRON_VERSION (raw: $ELECTRON_VERSION_RAW)"
log "better-sqlite3 Version: $BETTER_SQLITE3_VERSION (raw: $BETTER_SQLITE3_VERSION_RAW)"
log "node-pty Version: $NODE_PTY_VERSION (raw: $NODE_PTY_VERSION_RAW)"

# ---------------------------
# Build native modules
# ---------------------------
if [ ! -d "$NATIVE_BUILD_DIR" ]; then
    log "Building native modules..."
    mkdir -p "$NATIVE_BUILD_DIR"
    cd "$NATIVE_BUILD_DIR"

    # Initialize dummy package.json
    npm init -y > /dev/null

    # Install dependencies
    log "Installing dependencies for native build..."
    npm install electron@"$ELECTRON_VERSION" better-sqlite3@"$BETTER_SQLITE3_VERSION" node-pty@"$NODE_PTY_VERSION" --save
    npm install @electron/rebuild --save-dev

    # Rebuild
    log "Rebuilding native modules..."
    ./node_modules/.bin/electron-rebuild -v "$ELECTRON_VERSION" -m . -w better-sqlite3,node-pty

    cd "$ROOT_DIR"
else
    log "Native builds directory exists. Skipping rebuild (delete $NATIVE_BUILD_DIR to force)."
fi

# ---------------------------
# Copy native modules
# ---------------------------
log "Copying native modules to app..."

# better-sqlite3
mkdir -p "$APP_DIR/node_modules/better-sqlite3/build/Release"
cp "$NATIVE_BUILD_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
   "$APP_DIR/node_modules/better-sqlite3/build/Release/"

# node-pty
mkdir -p "$APP_DIR/node_modules/node-pty/build/Release"
if [ -f "$NATIVE_BUILD_DIR/node_modules/node-pty/build/Release/pty.node" ]; then
    cp "$NATIVE_BUILD_DIR/node_modules/node-pty/build/Release/pty.node" \
       "$APP_DIR/node_modules/node-pty/build/Release/"
else
    warn "pty.node not found in build/Release. Checking prebuilds..."
    PTY_FOUND=$(find "$NATIVE_BUILD_DIR/node_modules/node-pty" -name "pty.node" | head -n 1)
    if [ -n "$PTY_FOUND" ]; then
        cp "$PTY_FOUND" "$APP_DIR/node_modules/node-pty/build/Release/"
    else
        err "pty.node not found!"
        exit 1
    fi
fi

# ---------------------------
# Bundle with electron-builder
# ---------------------------
log "Bundling AppImage..."
mkdir -p "$DIST_DIR"

# We need to install electron-builder if not present
if ! command -v electron-builder &> /dev/null; then
    BUILDER_DIR="$WORK_DIR/builder"
    if [ ! -f "$BUILDER_DIR/node_modules/.bin/electron-builder" ]; then
        log "Installing electron-builder..."
        mkdir -p "$BUILDER_DIR"
        cd "$BUILDER_DIR"
        npm init -y > /dev/null
        npm install electron-builder --save-dev
        cd "$ROOT_DIR"
    fi
    BUILDER="$BUILDER_DIR/node_modules/.bin/electron-builder"
else
    BUILDER="electron-builder"
fi

# Prepare config
cat > "$WORK_DIR/electron-builder.yml" <<EOF
appId: com.openai.codex
productName: Codex
directories:
  output: ${DIST_DIR}
  app: ${APP_DIR}
linux:
  target: AppImage
  category: Development
npmRebuild: false
files:
  - "**/*"
  - "!**/node_modules/*/{CHANGELOG.md,README.md,README,readme.md,readme}"
  - "!**/node_modules/*/{test,__tests__,tests,powered-test,example,examples}"
  - "!**/node_modules/*.d.ts"
  - "!**/node_modules/.bin"
  - "!**/*.{iml,o,hprof,orig,pyc,pyo,rbc,swp,csproj,sln,xproj}"
  - "!.editorconfig"
  - "!.git"
  - "!.gitignore"
  - "!.npmignore"
  - "!build"
  - "!**/{.DS_Store,.git,.hg,.svn,CVS,RCS,SCCS,.gitignore,.gitattributes}"
  - "!**/{__pycache__,thumbs.db,.flowconfig,.idea,.vs,.nyc_output}"
  - "!**/{appveyor.yml,.travis.yml,circle.yml}"
  - "!**/{npm-debug.log,yarn.lock,.yarn-integrity,.yarn-metadata.json}"
EOF

# Run builder
log "Running electron-builder..."
# --publish never prevents CI autodetect from trying to publish artifacts/releases
"$BUILDER" build --config "$WORK_DIR/electron-builder.yml" --linux --publish never

log "Done! AppImage is in $DIST_DIR"
log "Note: You must have 'codex' CLI installed and in your PATH, or set CODEX_CLI_PATH environment variable before running the AppImage."
