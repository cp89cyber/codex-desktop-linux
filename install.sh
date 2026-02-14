#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# Codex Desktop for Linux — Installer
# Converts the official macOS Codex Desktop app to run on Linux
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${CODEX_INSTALL_DIR:-$SCRIPT_DIR/codex-app}"
ELECTRON_VERSION="40.0.0"
WORK_DIR="$(mktemp -d)"
ARCH="$(uname -m)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'error "Failed at line $LINENO (exit code $?)"' ERR

# ---- Utilities ----
is_valid_dmg() {
    local dmg_path="$1"
    [ -s "$dmg_path" ] || return 1
    # UDIF DMGs store the "koly" signature in the trailer.
    tail -c 2048 "$dmg_path" | grep -qa "koly"
}

get_7z_major_version() {
    local seven_zip_bin="$1"
    local line version
    line="$("$seven_zip_bin" i 2>/dev/null | sed -n '/[0-9][0-9]*\.[0-9][0-9]*/{p;q}' || true)"
    version=$(echo "$line" | grep -Eo '[0-9]{2,}\.[0-9]+' | head -n 1 || true)
    version="${version:-0.0}"
    echo "${version%%.*}"
}

resolve_7z_extractor() {
    if command -v 7zz &>/dev/null; then
        echo "$(command -v 7zz)"
        return
    fi

    if command -v 7z &>/dev/null; then
        local major
        major=$(get_7z_major_version 7z)
        if [ "$major" -ge 22 ]; then
            echo "$(command -v 7z)"
            return
        fi

        warn "Detected legacy 7z (major version: $major). Modern Codex DMGs need 7-Zip 22+."
    fi

    local seven_zip_dir="$WORK_DIR/7zip-bin"
    mkdir -p "$seven_zip_dir"
    info "Installing modern 7-Zip (7zz) via npm package 7zip-bin-full..."

    npm --prefix "$seven_zip_dir" install --no-save --silent 7zip-bin-full >&2 || \
        error "Could not install 7zip-bin-full. Install package '7zip' (provides 7zz) and retry."

    local bundled_7z
    bundled_7z=$(NODE_PATH="$seven_zip_dir/node_modules" node -e "process.stdout.write(require('7zip-bin-full').path7z)" 2>/dev/null || true)
    [ -x "$bundled_7z" ] || error "Bundled 7-Zip binary not found. Install package '7zip' and retry."

    echo "$bundled_7z"
}

# ---- Check dependencies ----
check_deps() {
    local missing=()
    for cmd in node npm npx python3 curl unzip; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v 7z &>/dev/null && ! command -v 7zz &>/dev/null; then
        missing+=("7z/7zz")
    fi
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing[*]}
Install them first:
  sudo apt install nodejs npm python3 7zip curl unzip build-essential  # Debian/Ubuntu
  sudo dnf install nodejs npm python3 p7zip curl unzip && sudo dnf groupinstall 'Development Tools'  # Fedora
  sudo pacman -S nodejs npm python p7zip curl unzip base-devel  # Arch"
    fi

    NODE_MAJOR=$(node -v | cut -d. -f1 | tr -d v)
    if [ "$NODE_MAJOR" -lt 20 ]; then
        error "Node.js 20+ required (found $(node -v))"
    fi

    if ! command -v make &>/dev/null || ! command -v g++ &>/dev/null; then
        error "Build tools (make, g++) required:
  sudo apt install build-essential   # Debian/Ubuntu
  sudo dnf groupinstall 'Development Tools'  # Fedora
  sudo pacman -S base-devel          # Arch"
    fi

    info "All dependencies found"
}

check_patch_deps() {
    local missing=()
    for cmd in node npm npx; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing dependencies for --patch-installed: ${missing[*]}"
    fi

    local node_major
    node_major=$(node -v | cut -d. -f1 | tr -d v)
    if [ "$node_major" -lt 20 ]; then
        error "Node.js 20+ required (found $(node -v))"
    fi
}

# ---- Download or find Codex DMG ----
get_dmg() {
    local dmg_dest="$SCRIPT_DIR/Codex.dmg"

    # Reuse existing DMG
    if [ -s "$dmg_dest" ]; then
        if is_valid_dmg "$dmg_dest"; then
            info "Using cached DMG: $dmg_dest ($(du -h "$dmg_dest" | cut -f1))"
            echo "$dmg_dest"
            return
        fi
        warn "Cached file is not a valid DMG trailer signature. Re-downloading: $dmg_dest"
        rm -f "$dmg_dest"
    fi

    info "Downloading Codex Desktop DMG..."
    local dmg_url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
    info "URL: $dmg_url"

    if ! curl -L --progress-bar --max-time 600 --connect-timeout 30 \
            -o "$dmg_dest" "$dmg_url"; then
        rm -f "$dmg_dest"
        error "Download failed. Download manually and place as: $dmg_dest"
    fi

    if [ ! -s "$dmg_dest" ]; then
        rm -f "$dmg_dest"
        error "Download produced empty file. Download manually and place as: $dmg_dest"
    fi

    if ! is_valid_dmg "$dmg_dest"; then
        rm -f "$dmg_dest"
        error "Downloaded file is not a valid DMG. Download manually and place as: $dmg_dest"
    fi

    info "Saved: $dmg_dest ($(du -h "$dmg_dest" | cut -f1))"
    echo "$dmg_dest"
}

# ---- Extract app from DMG ----
extract_dmg() {
    local dmg_path="$1"
    local seven_zip_bin
    seven_zip_bin="$(resolve_7z_extractor)"
    info "Extracting DMG with $(basename "$seven_zip_bin")..."

    rm -rf "$WORK_DIR/dmg-extract"
    "$seven_zip_bin" x -y "$dmg_path" -o"$WORK_DIR/dmg-extract" >&2 || \
        error "Failed to extract DMG. Install modern 7-Zip (7zz, version 22+) and retry."

    local app_dir
    app_dir=$(find "$WORK_DIR/dmg-extract" -maxdepth 3 -name "*.app" -type d | head -1)
    [ -n "$app_dir" ] || error "Could not find .app bundle in DMG"

    info "Found: $(basename "$app_dir")"
    echo "$app_dir"
}

# ---- Build native modules in a clean directory ----
build_native_modules() {
    local app_extracted="$1"

    # Read versions from extracted app
    local bs3_ver npty_ver
    bs3_ver=$(node -p "require('$app_extracted/node_modules/better-sqlite3/package.json').version" 2>/dev/null || echo "")
    npty_ver=$(node -p "require('$app_extracted/node_modules/node-pty/package.json').version" 2>/dev/null || echo "")

    [ -n "$bs3_ver" ] || error "Could not detect better-sqlite3 version"
    [ -n "$npty_ver" ] || error "Could not detect node-pty version"

    info "Native modules: better-sqlite3@$bs3_ver, node-pty@$npty_ver"

    # Build in a CLEAN directory (asar doesn't have full source)
    local build_dir="$WORK_DIR/native-build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    echo '{"private":true}' > package.json

    info "Installing fresh sources from npm..."
    npm install "electron@$ELECTRON_VERSION" --save-dev --ignore-scripts 2>&1 >&2
    npm install "better-sqlite3@$bs3_ver" "node-pty@$npty_ver" --ignore-scripts 2>&1 >&2

    info "Compiling for Electron v$ELECTRON_VERSION (this takes ~1 min)..."
    npx --yes @electron/rebuild -v "$ELECTRON_VERSION" --force 2>&1 >&2

    info "Native modules built successfully"

    # Copy compiled modules back into extracted app
    rm -rf "$app_extracted/node_modules/better-sqlite3"
    rm -rf "$app_extracted/node_modules/node-pty"
    cp -r "$build_dir/node_modules/better-sqlite3" "$app_extracted/node_modules/"
    cp -r "$build_dir/node_modules/node-pty" "$app_extracted/node_modules/"
}

# ---- Patch transparent window background in Electron main bundle ----
patch_window_background_opacity() {
    local asar_extracted="$1"
    local build_dir="$asar_extracted/.vite/build"
    local bundle_path
    local transparent_before
    local patched_before
    local transparent_after
    local patched_after
    local old_expr='="#00000000"'
    local new_expr='=process.platform==="linux"?"#f2f2f2":"#00000000"'

    [ -d "$build_dir" ] || error "Main process build directory not found: $build_dir"

    bundle_path=$(find "$build_dir" -maxdepth 1 -type f -name 'main-*.js' | head -n 1)
    [ -n "$bundle_path" ] || error "Could not find main-*.js bundle in $build_dir"

    patched_before=$( (grep -F -o "$new_expr" "$bundle_path" || true) | wc -l | tr -d '[:space:]')
    if [ "$patched_before" -eq 1 ]; then
        info "Window opacity patch already present in $(basename "$bundle_path")"
        return
    fi
    [ "$patched_before" -eq 0 ] || error "Window opacity patch mismatch in $(basename "$bundle_path"): expected 0/1 patched matches, got $patched_before"

    transparent_before=$( (grep -F -o "$old_expr" "$bundle_path" || true) | wc -l | tr -d '[:space:]')
    [ "$transparent_before" -eq 1 ] || error "Window transparency pattern mismatch in $(basename "$bundle_path"): expected 1 match, got $transparent_before"

    info "Applying window opacity patch to $(basename "$bundle_path")..."
    perl -0777 -i -pe \
        's/=\"#00000000\"/=process.platform==="linux"?"#f2f2f2":"#00000000"/g' \
        "$bundle_path"

    patched_after=$( (grep -F -o "$new_expr" "$bundle_path" || true) | wc -l | tr -d '[:space:]')
    transparent_after=$( (grep -F -o "$old_expr" "$bundle_path" || true) | wc -l | tr -d '[:space:]')

    [ "$patched_after" -eq 1 ] || error "Window opacity patch validation failed in $(basename "$bundle_path"): expected 1 patched match, got $patched_after"
    [ "$transparent_after" -eq 0 ] || error "Window opacity patch validation failed in $(basename "$bundle_path"): expected 0 legacy matches, got $transparent_after"

    info "Window opacity patch applied"
}

# ---- Extract and patch app.asar ----
patch_asar() {
    local app_dir="$1"
    local resources_dir="$app_dir/Contents/Resources"

    [ -f "$resources_dir/app.asar" ] || error "app.asar not found in $resources_dir"

    info "Extracting app.asar..."
    cd "$WORK_DIR"
    npx --yes asar extract "$resources_dir/app.asar" app-extracted

    # Copy unpacked native modules if they exist
    if [ -d "$resources_dir/app.asar.unpacked" ]; then
        cp -r "$resources_dir/app.asar.unpacked/"* app-extracted/ 2>/dev/null || true
    fi

    # Remove macOS-only modules
    rm -rf "$WORK_DIR/app-extracted/node_modules/sparkle-darwin" 2>/dev/null || true
    find "$WORK_DIR/app-extracted" -name "sparkle.node" -delete 2>/dev/null || true

    # Build native modules in clean environment and copy back
    build_native_modules "$WORK_DIR/app-extracted"
    patch_window_background_opacity "$WORK_DIR/app-extracted"

    # Repack
    info "Repacking app.asar..."
    cd "$WORK_DIR"
    npx asar pack app-extracted app.asar --unpack "{*.node,*.so,*.dylib}" 2>/dev/null

    info "app.asar patched"
}

# ---- Patch existing installed app in place ----
patch_installed_app() {
    local target_install_dir="$1"
    local resolved_install_dir
    local resources_dir
    local app_asar
    local extract_dir
    local repacked_asar
    local repacked_unpacked
    local backup_path
    local ts

    resolved_install_dir=$(realpath "$target_install_dir" 2>/dev/null || true)
    [ -n "$resolved_install_dir" ] || error "Install directory not found: $target_install_dir"

    resources_dir="$resolved_install_dir/resources"
    app_asar="$resources_dir/app.asar"
    [ -f "$app_asar" ] || error "app.asar not found in $resources_dir"

    info "Patching installed app in: $resolved_install_dir"

    extract_dir="$WORK_DIR/app-extracted-installed"
    repacked_asar="$WORK_DIR/app.asar.patched"
    repacked_unpacked="$repacked_asar.unpacked"

    npx --yes asar extract "$app_asar" "$extract_dir"
    patch_window_background_opacity "$extract_dir"

    info "Repacking patched app.asar..."
    cd "$WORK_DIR"
    npx asar pack "$extract_dir" "$repacked_asar" --unpack "{*.node,*.so,*.dylib}" 2>/dev/null

    ts=$(date +%Y%m%d-%H%M%S)
    backup_path="$resources_dir/app.asar.bak.$ts"
    cp "$app_asar" "$backup_path"
    cp "$repacked_asar" "$app_asar"

    if [ -d "$repacked_unpacked" ]; then
        rm -rf "$resources_dir/app.asar.unpacked"
        cp -r "$repacked_unpacked" "$resources_dir/app.asar.unpacked"
    fi

    info "Backup created: $backup_path"
    info "Installed app patched successfully"
}

# ---- Patch sidebar width behavior in webview bundle ----
patch_sidebar_width_clamp() {
    local asar_extracted="$WORK_DIR/app-extracted"
    local assets_dir="$asar_extracted/webview/assets"
    local bundle_path
    local constants_before
    local clamp_before
    local constants_after
    local clamp_after
    local old_constants='const XJ=300,HCe=240,UCe=520,u5t=320,d5t=bo("sidebar-width",XJ);'
    local new_constants='const XJ=280,HCe=220,UCe=420,u5t=560,d5t=bo("sidebar-width",XJ);'
    local old_clamp='clamp(${HCe}px, ${e}px, min(${UCe}px, calc(100vw - ${u5t}px)))'
    local new_clamp='clamp(${HCe}px, ${e}px, min(${UCe}px, 38vw, calc(100vw - ${u5t}px)))'

    [ -d "$assets_dir" ] || error "Webview assets directory not found: $assets_dir"

    bundle_path=$(grep -R -l 'bo("sidebar-width"' "$assets_dir" 2>/dev/null | head -n 1 || true)
    [ -n "$bundle_path" ] || error "Could not find webview sidebar bundle to patch"

    constants_before=$( (grep -F -o "$old_constants" "$bundle_path" || true) | wc -l | tr -d '[:space:]')
    clamp_before=$( (grep -F -o "$old_clamp" "$bundle_path" || true) | wc -l | tr -d '[:space:]')

    [ "$constants_before" -eq 1 ] || error "Sidebar constants pattern mismatch in $(basename "$bundle_path"): expected 1 match, got $constants_before"
    [ "$clamp_before" -eq 1 ] || error "Sidebar clamp pattern mismatch in $(basename "$bundle_path"): expected 1 match, got $clamp_before"

    info "Applying sidebar width clamp patch to $(basename "$bundle_path")..."

    perl -0777 -i -pe \
        's/const XJ=300,HCe=240,UCe=520,u5t=320,d5t=bo\("sidebar-width",XJ\);/const XJ=280,HCe=220,UCe=420,u5t=560,d5t=bo("sidebar-width",XJ);/g;
         s/clamp\(\$\{HCe\}px, \$\{e\}px, min\(\$\{UCe\}px, calc\(100vw - \$\{u5t\}px\)\)\)/clamp(\${HCe}px, \${e}px, min(\${UCe}px, 38vw, calc(100vw - \${u5t}px)))/g' \
        "$bundle_path"

    constants_after=$( (grep -F -o "$new_constants" "$bundle_path" || true) | wc -l | tr -d '[:space:]')
    clamp_after=$( (grep -F -o "$new_clamp" "$bundle_path" || true) | wc -l | tr -d '[:space:]')

    [ "$constants_after" -eq 1 ] || error "Sidebar constants patch validation failed in $(basename "$bundle_path"): expected 1 updated match, got $constants_after"
    [ "$clamp_after" -eq 1 ] || error "Sidebar clamp patch validation failed in $(basename "$bundle_path"): expected 1 updated match, got $clamp_after"

    info "Sidebar width clamp patch applied"
}

# ---- Download Linux Electron ----
download_electron() {
    info "Downloading Electron v${ELECTRON_VERSION} for Linux..."

    local electron_arch
    case "$ARCH" in
        x86_64)  electron_arch="x64" ;;
        aarch64) electron_arch="arm64" ;;
        armv7l)  electron_arch="armv7l" ;;
        *)       error "Unsupported architecture: $ARCH" ;;
    esac

    local url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"

    curl -L --progress-bar -o "$WORK_DIR/electron.zip" "$url"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    unzip -qo "$WORK_DIR/electron.zip"

    info "Electron ready"
}

# ---- Extract webview files ----
extract_webview() {
    local app_dir="$1"
    mkdir -p "$INSTALL_DIR/content/webview"

    # Webview files are inside the extracted asar at webview/
    local asar_extracted="$WORK_DIR/app-extracted"
    if [ -d "$asar_extracted/webview" ]; then
        cp -r "$asar_extracted/webview/"* "$INSTALL_DIR/content/webview/"
        info "Webview files copied"
    else
        warn "Webview directory not found in asar — app may not work"
    fi
}

# ---- Install app.asar ----
install_app() {
    cp "$WORK_DIR/app.asar" "$INSTALL_DIR/resources/"
    if [ -d "$WORK_DIR/app.asar.unpacked" ]; then
        cp -r "$WORK_DIR/app.asar.unpacked" "$INSTALL_DIR/resources/"
    fi
    info "app.asar installed"
}

# ---- Create start script ----
create_start_script() {
    cat > "$INSTALL_DIR/start.sh" << 'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBVIEW_DIR="$SCRIPT_DIR/content/webview"
ELECTRON_BIN="$SCRIPT_DIR/electron"

check_electron_runtime_libs() {
    local missing_libs=()
    local os_id=""

    mapfile -t missing_libs < <(ldd "$ELECTRON_BIN" 2>/dev/null | awk '/not found/ {print $1}')
    if [ "${#missing_libs[@]}" -eq 0 ]; then
        return
    fi

    echo "Error: Missing shared libraries required by Electron:"
    for lib in "${missing_libs[@]}"; do
        echo "  - $lib"
    done

    if [ -r /etc/os-release ]; then
        os_id="$(. /etc/os-release; echo "${ID:-}")"
    fi

    case "$os_id" in
        debian|ubuntu|linuxmint|pop|zorin|elementary)
            echo "Install with: sudo apt install libnspr4 libnss3"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            echo "Install with: sudo dnf install nspr nss"
            ;;
        arch|manjaro|endeavouros)
            echo "Install with: sudo pacman -S nspr nss"
            ;;
        *)
            echo "Install distro packages that provide the missing libraries above."
            ;;
    esac
    exit 1
}

check_electron_runtime_libs

pkill -f "http.server 5175" 2>/dev/null
sleep 0.3

if [ -d "$WEBVIEW_DIR" ] && [ "$(ls -A "$WEBVIEW_DIR" 2>/dev/null)" ]; then
    cd "$WEBVIEW_DIR"
    python3 -m http.server 5175 &> /dev/null &
    HTTP_PID=$!
    trap "kill $HTTP_PID 2>/dev/null" EXIT
fi

export CODEX_CLI_PATH="${CODEX_CLI_PATH:-$(which codex 2>/dev/null)}"

if [ -z "$CODEX_CLI_PATH" ]; then
    echo "Error: Codex CLI not found. Install with: npm i -g @openai/codex"
    exit 1
fi

cd "$SCRIPT_DIR"
exec "$ELECTRON_BIN" --no-sandbox "$@"
SCRIPT

    chmod +x "$INSTALL_DIR/start.sh"
    info "Start script created"
}

# ---- Main ----
main() {
    echo "============================================" >&2
    echo "  Codex Desktop for Linux — Installer"       >&2
    echo "============================================" >&2
    echo ""                                             >&2

    if [ $# -ge 1 ] && [ "$1" = "--patch-installed" ]; then
        local patch_target="${2:-$INSTALL_DIR}"
        [ $# -le 2 ] || error "Usage: ./install.sh --patch-installed [install_dir]"
        check_patch_deps
        patch_installed_app "$patch_target"
        return
    fi

    check_deps

    local dmg_path=""
    if [ $# -ge 1 ] && [ -f "$1" ]; then
        dmg_path="$(realpath "$1")"
        info "Using provided DMG: $dmg_path"
    else
        dmg_path=$(get_dmg)
    fi

    local app_dir
    app_dir=$(extract_dmg "$dmg_path")

    patch_asar "$app_dir"
    patch_sidebar_width_clamp
    download_electron
    extract_webview "$app_dir"
    install_app
    create_start_script

    if ! command -v codex &>/dev/null; then
        warn "Codex CLI not found. Install it: npm i -g @openai/codex"
    fi

    echo ""                                             >&2
    echo "============================================" >&2
    info "Installation complete!"
    echo "  Run:  $INSTALL_DIR/start.sh"                >&2
    echo "============================================" >&2
}

main "$@"
