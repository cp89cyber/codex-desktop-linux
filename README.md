# Atlas Desktop for Linux

Run Atlas on Linux using an Atlas DMG input and a Linux Electron wrapper.

## What this installer does

The installer accepts Atlas DMGs and produces a runnable Linux app wrapper in `atlas-app/` (by default).

Supported inputs:

- Atlas installer DMG (`Install_ChatGPT_Atlas.dmg`)
- Atlas payload DMG (`ChatGPT_Atlas.dmg`)

Unsupported inputs:

- DMGs containing `Contents/Resources/app.asar` (explicitly rejected)

## Prerequisites

- Node.js 20+
- npm
- 7z or 7zz (installer can bootstrap modern `7zz` via `7zip-bin-full`)
- curl
- unzip

### Debian/Ubuntu

```bash
sudo apt install nodejs npm 7zip curl unzip
```

### Fedora

```bash
sudo dnf install nodejs npm p7zip curl unzip
```

### Arch

```bash
sudo pacman -S nodejs npm p7zip curl unzip
```

## Installation

### Option A: Auto-detect local DMGs (payload first), then download fallback

```bash
git clone https://github.com/ilysenko/codex-desktop-linux.git
cd codex-desktop-linux
chmod +x install.sh
./install.sh
```

When no DMG path is provided, source precedence is:

1. `ATLAS_PAYLOAD_DMG` (must exist and be a valid DMG)
2. `./ChatGPT_Atlas.dmg` next to `install.sh`
3. `$PWD/ChatGPT_Atlas.dmg`
4. `./Install_ChatGPT_Atlas.dmg` next to `install.sh`
5. Download default installer DMG from `ATLAS_INSTALLER_URL_DEFAULT`

### Option B: Provide your own Atlas DMG

```bash
./install.sh /path/to/Install_ChatGPT_Atlas.dmg
# or
./install.sh /path/to/ChatGPT_Atlas.dmg
```

### Optional payload override env var

Set `ATLAS_PAYLOAD_DMG` to force a specific local payload DMG path.

```bash
ATLAS_PAYLOAD_DMG=/path/to/ChatGPT_Atlas.dmg ./install.sh
```

If input is an Atlas installer DMG, payload resolution precedence is:

1. `ATLAS_PAYLOAD_DMG`
2. `./ChatGPT_Atlas.dmg` next to `install.sh`
3. `$PWD/ChatGPT_Atlas.dmg`
4. Download payload DMG from installer-derived URL (fallback)

## Install location

Install directory precedence:

1. `ATLAS_INSTALL_DIR`
2. `CODEX_INSTALL_DIR` (deprecated fallback; installer prints warning)
3. Default: `./atlas-app`

Examples:

```bash
ATLAS_INSTALL_DIR=/opt/atlas ./install.sh /path/to/Install_ChatGPT_Atlas.dmg
```

```bash
CODEX_INSTALL_DIR=/opt/atlas-legacy ./install.sh /path/to/Install_ChatGPT_Atlas.dmg
```

## Atlas start URL behavior

Launch URL precedence:

1. `ATLAS_START_URL` env var
2. URL hint extracted from Atlas payload/installer
3. Fallback: `https://chatgpt.com/atlas?get-started`

Example override:

```bash
ATLAS_START_URL="https://example.test" ./atlas-app/start.sh
```

## Removed option

`--patch-installed` has been removed. It was specific to older non-Atlas conversion behavior.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `error while loading shared libraries: libnspr4.so` (or `libnss3.so`) | Install Electron runtime libs: `sudo apt install libnspr4 libnss3` (Debian/Ubuntu), `sudo dnf install nspr nss` (Fedora/RHEL), `sudo pacman -S nspr nss` (Arch) |
| Atlas DMG is rejected as unsupported | Verify you supplied an Atlas DMG. DMGs with `app.asar` are intentionally unsupported. |
| Atlas app installs but does not launch | Run `./atlas-app/start.sh` directly and verify required runtime libraries are present. |

## Disclaimer

This is an unofficial community project. Atlas is a product of OpenAI.

## License

MIT
