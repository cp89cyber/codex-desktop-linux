#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# Atlas Desktop for Linux — Installer
# Converts Atlas macOS DMGs into a Linux Electron wrapper app
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR=""
ELECTRON_VERSION="40.0.0"
ATLAS_INSTALLER_URL_DEFAULT="https://persistent.oaistatic.com/atlas/public/Install_ChatGPT_Atlas.dmg"
ATLAS_PAYLOAD_FALLBACK_URL="https://persistent.oaistatic.com/atlas/public/ChatGPT_Atlas.dmg"
ATLAS_START_URL_FALLBACK="https://chatgpt.com/atlas?get-started"
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
    tail -c 2048 "$dmg_path" | grep -qa "koly"
}

get_7z_major_version() {
    local seven_zip_bin="$1"
    local line version
    line="$($seven_zip_bin i 2>/dev/null | sed -n '/[0-9][0-9]*\.[0-9][0-9]*/{p;q}' || true)"
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

        warn "Detected legacy 7z (major version: $major). Modern Atlas DMGs need 7-Zip 22+."
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

resolve_install_dir() {
    if [ -n "${ATLAS_INSTALL_DIR:-}" ]; then
        INSTALL_DIR="$ATLAS_INSTALL_DIR"
        return
    fi

    if [ -n "${CODEX_INSTALL_DIR:-}" ]; then
        warn "CODEX_INSTALL_DIR is deprecated. Use ATLAS_INSTALL_DIR instead."
        INSTALL_DIR="$CODEX_INSTALL_DIR"
        return
    fi

    INSTALL_DIR="$SCRIPT_DIR/atlas-app"
}

app_main_binary_path() {
    local app_dir="$1"
    local app_name
    app_name="$(basename "$app_dir" .app)"
    echo "$app_dir/Contents/MacOS/$app_name"
}

find_url_in_file() {
    local file_path="$1"
    local pattern="$2"

    [ -f "$file_path" ] || return 1

    if command -v strings &>/dev/null; then
        strings "$file_path" 2>/dev/null | grep -Eo "https?://[^\"'[:space:]]+" | grep -E "$pattern" | head -n 1
        return
    fi

    grep -a -Eo "https?://[^\"'[:space:]]+" "$file_path" 2>/dev/null | grep -E "$pattern" | head -n 1
}

binary_contains() {
    local file_path="$1"
    local needle="$2"

    [ -f "$file_path" ] || return 1

    if command -v strings &>/dev/null; then
        strings "$file_path" 2>/dev/null | grep -Fq "$needle"
        return
    fi

    grep -a -Fq "$needle" "$file_path" 2>/dev/null
}

find_local_payload_dmg() {
    local explicit_payload_dmg="${ATLAS_PAYLOAD_DMG:-}"
    local script_payload_dmg="$SCRIPT_DIR/ChatGPT_Atlas.dmg"
    local cwd_payload_dmg="$PWD/ChatGPT_Atlas.dmg"
    local canonical_script_payload=""
    local canonical_cwd_payload=""

    if [ -n "$explicit_payload_dmg" ]; then
        [ -f "$explicit_payload_dmg" ] || error "ATLAS_PAYLOAD_DMG points to a missing file: $explicit_payload_dmg"
        explicit_payload_dmg="$(realpath "$explicit_payload_dmg")"
        is_valid_dmg "$explicit_payload_dmg" || error "ATLAS_PAYLOAD_DMG is not a valid DMG: $explicit_payload_dmg"
        echo "$explicit_payload_dmg"
        return
    fi

    if [ -f "$script_payload_dmg" ]; then
        canonical_script_payload="$(realpath "$script_payload_dmg")"
        if is_valid_dmg "$canonical_script_payload"; then
            echo "$canonical_script_payload"
            return
        fi
        warn "Ignoring invalid local payload DMG: $canonical_script_payload"
    fi

    if [ -f "$cwd_payload_dmg" ]; then
        canonical_cwd_payload="$(realpath "$cwd_payload_dmg")"
        if [ "$canonical_cwd_payload" != "$canonical_script_payload" ]; then
            if is_valid_dmg "$canonical_cwd_payload"; then
                echo "$canonical_cwd_payload"
                return
            fi
            warn "Ignoring invalid local payload DMG: $canonical_cwd_payload"
        fi
    fi

    return 1
}

is_codex_shape_app() {
    local app_dir="$1"
    [ -f "$app_dir/Contents/Resources/app.asar" ]
}

is_atlas_like_app() {
    local app_dir="$1"
    local app_name
    local main_bin
    local sig

    if [ -d "$app_dir/Contents/Support/ChatGPT Atlas.app" ]; then
        return 0
    fi

    app_name="$(basename "$app_dir")"
    if [[ "$app_name" == *"Atlas"* ]]; then
        return 0
    fi

    main_bin="$(app_main_binary_path "$app_dir")"
    if [ -f "$main_bin" ]; then
        for sig in \
            "chatgpt.com/atlas" \
            "com.openai.atlas" \
            "/atlas/public/ChatGPT_Atlas.dmg" \
            "Install_ChatGPT_Atlas.dmg" \
            "ChatGPT_Atlas.dmg"; do
            if binary_contains "$main_bin" "$sig"; then
                return 0
            fi
        done
    fi

    return 1
}

is_atlas_installer_app() {
    local app_dir="$1"
    local main_bin
    local sig

    main_bin="$(app_main_binary_path "$app_dir")"
    [ -f "$main_bin" ] || return 1

    for sig in \
        "Install_ChatGPT_Atlas.dmg" \
        "/atlas/public/ChatGPT_Atlas.dmg" \
        "InstallerAppIcon.icns"; do
        if binary_contains "$main_bin" "$sig"; then
            return 0
        fi
    done

    return 1
}

# ---- Dependency checks ----
check_deps() {
    local missing=()
    for cmd in node npm curl unzip; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v 7z &>/dev/null && ! command -v 7zz &>/dev/null; then
        missing+=("7z/7zz")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing[*]}
Install them first:
  sudo apt install nodejs npm 7zip curl unzip      # Debian/Ubuntu
  sudo dnf install nodejs npm p7zip curl unzip      # Fedora
  sudo pacman -S nodejs npm p7zip curl unzip        # Arch"
    fi

    local node_major
    node_major=$(node -v | cut -d. -f1 | tr -d v)
    if [ "$node_major" -lt 20 ]; then
        error "Node.js 20+ required (found $(node -v))"
    fi

    info "All dependencies found"
}

# ---- Resolve local DMG or download installer fallback ----
get_dmg() {
    local local_payload_dmg=""
    local installer_dmg="$SCRIPT_DIR/Install_ChatGPT_Atlas.dmg"

    local_payload_dmg=$(find_local_payload_dmg || true)
    if [ -n "$local_payload_dmg" ]; then
        info "Using local Atlas payload DMG: $local_payload_dmg ($(du -h "$local_payload_dmg" | cut -f1))"
        echo "$local_payload_dmg"
        return
    fi

    if [ -s "$installer_dmg" ]; then
        if is_valid_dmg "$installer_dmg"; then
            info "Using cached Atlas installer DMG: $installer_dmg ($(du -h "$installer_dmg" | cut -f1))"
            echo "$installer_dmg"
            return
        fi
        warn "Cached installer file is not a valid DMG. Re-downloading: $installer_dmg"
        rm -f "$installer_dmg"
    fi

    info "No local Atlas DMG found; downloading Atlas installer DMG..."
    info "URL: $ATLAS_INSTALLER_URL_DEFAULT"

    if ! curl -L --progress-bar --max-time 600 --connect-timeout 30 \
            -o "$installer_dmg" "$ATLAS_INSTALLER_URL_DEFAULT"; then
        rm -f "$installer_dmg"
        error "Download failed. Download manually and place as: $installer_dmg"
    fi

    [ -s "$installer_dmg" ] || error "Download produced empty file: $installer_dmg"
    is_valid_dmg "$installer_dmg" || error "Downloaded file is not a valid DMG: $installer_dmg"

    info "Saved installer DMG: $installer_dmg ($(du -h "$installer_dmg" | cut -f1))"
    echo "$installer_dmg"
}

# ---- Extract app bundle from DMG ----
extract_dmg_to() {
    local dmg_path="$1"
    local output_dir="$2"
    local seven_zip_bin

    seven_zip_bin="$(resolve_7z_extractor)"
    info "Extracting DMG with $(basename "$seven_zip_bin")..."

    rm -rf "$output_dir"
    "$seven_zip_bin" x -y "$dmg_path" -o"$output_dir" >&2 || \
        error "Failed to extract DMG. Install modern 7-Zip (7zz, version 22+) and retry."

    local app_dir
    app_dir=$(find "$output_dir" -maxdepth 5 -name "*.app" -type d | head -1)
    [ -n "$app_dir" ] || error "Could not find .app bundle in DMG"

    info "Found: $(basename "$app_dir")"
    echo "$app_dir"
}

extract_dmg() {
    extract_dmg_to "$1" "$WORK_DIR/dmg-extract"
}

atlas_payload_url_from_installer() {
    local installer_app_dir="$1"
    local main_bin
    local url

    main_bin="$(app_main_binary_path "$installer_app_dir")"
    url=$(find_url_in_file "$main_bin" 'atlas/public/ChatGPT_Atlas\.dmg' || true)
    [ -n "$url" ] && echo "$url"
}

resolve_atlas_payload_app() {
    local extracted_app_dir="$1"
    local local_payload_dmg=""
    local payload_url
    local payload_dmg="$WORK_DIR/ChatGPT_Atlas.dmg"
    local atlas_app_dir

    if is_codex_shape_app "$extracted_app_dir"; then
        error "Unsupported DMG: detected app.asar (Codex-style package). This installer is Atlas-only."
    fi

    if [ -d "$extracted_app_dir/Contents/Support/ChatGPT Atlas.app" ]; then
        info "Using Atlas payload app bundle from extracted DMG."
        echo "$extracted_app_dir"
        return
    fi

    is_atlas_like_app "$extracted_app_dir" || \
        error "Unsupported DMG: no Atlas app signatures found."

    if ! is_atlas_installer_app "$extracted_app_dir"; then
        info "Using Atlas payload-like app bundle from extracted DMG."
        echo "$extracted_app_dir"
        return
    fi

    local_payload_dmg=$(find_local_payload_dmg || true)
    if [ -n "$local_payload_dmg" ]; then
        info "Atlas installer detected; using local payload DMG: $local_payload_dmg"
        atlas_app_dir=$(extract_dmg_to "$local_payload_dmg" "$WORK_DIR/atlas-payload-extract-local")

        if is_codex_shape_app "$atlas_app_dir"; then
            error "Unsupported payload: detected app.asar (Codex-style package). This installer is Atlas-only."
        fi

        is_atlas_like_app "$atlas_app_dir" || error "Local Atlas payload DMG does not contain a compatible Atlas app bundle"

        echo "$atlas_app_dir"
        return
    fi

    payload_url=$(atlas_payload_url_from_installer "$extracted_app_dir" || true)
    [ -n "$payload_url" ] || payload_url="$ATLAS_PAYLOAD_FALLBACK_URL"

    info "Atlas installer detected; no local payload DMG found. Fetching payload DMG..."
    info "Payload URL: $payload_url"

    if ! curl -L --progress-bar --max-time 900 --connect-timeout 30 \
            -o "$payload_dmg" "$payload_url"; then
        error "Failed to download Atlas payload DMG from: $payload_url"
    fi

    [ -s "$payload_dmg" ] || error "Atlas payload download produced an empty file"
    is_valid_dmg "$payload_dmg" || error "Downloaded Atlas payload is not a valid DMG"

    atlas_app_dir=$(extract_dmg_to "$payload_dmg" "$WORK_DIR/atlas-payload-extract")

    if is_codex_shape_app "$atlas_app_dir"; then
        error "Unsupported payload: detected app.asar (Codex-style package). This installer is Atlas-only."
    fi

    is_atlas_like_app "$atlas_app_dir" || error "Atlas payload DMG does not contain a compatible Atlas app bundle"

    echo "$atlas_app_dir"
}

extract_atlas_start_url_hint() {
    local app_dir="$1"
    local main_bin
    local support_bin
    local manifest_dir
    local url=""
    local file_path

    main_bin="$(app_main_binary_path "$app_dir")"
    support_bin="$app_dir/Contents/Support/ChatGPT Atlas.app/Contents/MacOS/ChatGPT Atlas"
    manifest_dir="$app_dir/Contents/Support/ChatGPT Atlas.app/Contents/Resources/com.openai.atlas.web.manifest"

    url=$(find_url_in_file "$support_bin" 'chatgpt\.com/atlas[^[:space:]]*' || true)
    [ -n "$url" ] || url=$(find_url_in_file "$main_bin" 'chatgpt\.com/atlas[^[:space:]]*' || true)

    if [ -z "$url" ] && [ -d "$manifest_dir" ]; then
        while IFS= read -r file_path; do
            url=$(find_url_in_file "$file_path" 'chatgpt\.com/atlas[^[:space:]]*' || true)
            [ -n "$url" ] && break
        done < <(find "$manifest_dir" -type f 2>/dev/null)
    fi

    [ -n "$url" ] && echo "$url"
}

resolve_atlas_start_url() {
    local atlas_app_dir="$1"
    local installer_app_dir="${2:-}"
    local hinted_url=""

    if [ -n "${ATLAS_START_URL:-}" ]; then
        echo "$ATLAS_START_URL"
        return
    fi

    hinted_url=$(extract_atlas_start_url_hint "$atlas_app_dir" || true)
    if [ -z "$hinted_url" ] && [ -n "$installer_app_dir" ]; then
        hinted_url=$(extract_atlas_start_url_hint "$installer_app_dir" || true)
    fi

    if [ -n "$hinted_url" ]; then
        echo "$hinted_url"
        return
    fi

    echo "$ATLAS_START_URL_FALLBACK"
}

find_atlas_icon_path() {
    local atlas_app_dir="$1"
    local candidate

    for candidate in \
        "$atlas_app_dir/Contents/Support/ChatGPT Atlas.app/Contents/Resources/app.icns" \
        "$atlas_app_dir/Contents/Resources/AppIcon.icns" \
        "$atlas_app_dir/Contents/Resources/InstallerAppIcon.icns"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
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

# ---- Install Atlas wrapper app ----
install_atlas_wrapper_app() {
    local atlas_start_url="$1"
    local atlas_icon_path="${2:-}"
    local escaped_url

    escaped_url=$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$atlas_start_url")

    mkdir -p "$INSTALL_DIR/resources/app"

    cat > "$INSTALL_DIR/resources/app/package.json" << 'JSON'
{
  "name": "chatgpt-atlas-linux-wrapper",
  "version": "1.0.0",
  "private": true,
  "main": "main.js"
}
JSON

    cat > "$INSTALL_DIR/resources/app/main.js" <<MAINJS
const { app, BrowserWindow, shell } = require("electron");

const fallbackUrl = $escaped_url;
const startUrl = process.env.ATLAS_START_URL || fallbackUrl;

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 960,
    minHeight: 640,
    autoHideMenuBar: true,
    backgroundColor: "#ffffff",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });

  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });

  win.loadURL(startUrl);
}

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});
MAINJS

    if [ -n "$atlas_icon_path" ] && [ -f "$atlas_icon_path" ]; then
        cp "$atlas_icon_path" "$INSTALL_DIR/resources/app/app.icns"
    fi

    info "Atlas wrapper app installed"
}

# ---- Create Atlas start script ----
create_atlas_start_script() {
    cat > "$INSTALL_DIR/start.sh" << 'START'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/resources/app"
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

if [ ! -d "$APP_DIR" ]; then
    echo "Error: Atlas wrapper app directory not found: $APP_DIR"
    exit 1
fi

cd "$SCRIPT_DIR"
exec "$ELECTRON_BIN" --no-sandbox "$APP_DIR" "$@"
START

    chmod +x "$INSTALL_DIR/start.sh"
    info "Atlas start script created"
}

# ---- Main ----
main() {
    echo "============================================" >&2
    echo "  Atlas Desktop for Linux — Installer"      >&2
    echo "============================================" >&2
    echo ""                                            >&2

    if [ $# -ge 1 ] && [ "$1" = "--patch-installed" ]; then
        error "The --patch-installed option was removed. It was Codex-only and is not available in this Atlas-only installer."
    fi

    [ $# -le 1 ] || error "Usage: ./install.sh [Install_ChatGPT_Atlas.dmg|ChatGPT_Atlas.dmg]"

    check_deps
    resolve_install_dir
    info "Install directory: $INSTALL_DIR"

    local dmg_path=""
    if [ $# -eq 1 ]; then
        [ -f "$1" ] || error "DMG not found: $1"
        dmg_path="$(realpath "$1")"
        info "Using provided DMG: $dmg_path"
    else
        dmg_path=$(get_dmg)
    fi

    local app_dir
    local atlas_app_dir
    local atlas_start_url
    local atlas_icon_path

    app_dir=$(extract_dmg "$dmg_path")

    if is_codex_shape_app "$app_dir"; then
        error "Unsupported DMG: detected app.asar (Codex-style package). This installer is Atlas-only."
    fi

    is_atlas_like_app "$app_dir" || error "Unsupported DMG: no Atlas signatures found."

    atlas_app_dir=$(resolve_atlas_payload_app "$app_dir")
    atlas_start_url=$(resolve_atlas_start_url "$atlas_app_dir" "$app_dir")
    atlas_icon_path=$(find_atlas_icon_path "$atlas_app_dir" || true)

    info "Atlas start URL: $atlas_start_url"

    download_electron
    install_atlas_wrapper_app "$atlas_start_url" "$atlas_icon_path"

    create_atlas_start_script

    echo ""                                            >&2
    echo "============================================" >&2
    info "Installation complete!"
    echo "  Run:  $INSTALL_DIR/start.sh"               >&2
    echo "============================================" >&2
}

main "$@"
