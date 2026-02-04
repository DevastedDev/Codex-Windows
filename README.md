# Codex DMG -> Windows / Linux

This repository provides tools to extract the macOS Codex DMG and run the Electron app on Windows or bundle it as an AppImage for Linux. It unpacks `app.asar`, swaps native modules, and launches/packages the app. It **does not** ship OpenAI binaries or assets; you must supply your own DMG and install the Codex CLI.

## Requirements

### Windows
- Windows 10/11
- Node.js
- 7-Zip (`7z` in PATH)
- If 7-Zip is not installed, the runner will try `winget` or download a portable copy
- Codex CLI installed (`npm i -g @openai/codex`)

### Linux
- Node.js
- `p7zip-full` (for `7z` command)
- Codex CLI installed (`npm i -g @openai/codex`)

## Quick Start

### Windows
1. Place your DMG in the repo root (default name `Codex.dmg`).
2. Run:

```powershell
.\scripts\run.ps1
```

Or explicitly:

```powershell
.\scripts\run.ps1 -DmgPath .\Codex.dmg
```

Or use the shortcut launcher:

```cmd
run.cmd
```

### Linux (AppImage Bundling)
1. Place your DMG in the repo root (default name `Codex.dmg`).
2. Run:

```bash
./scripts/bundle_linux.sh
```

The script will produce a `.AppImage` in the `dist/` directory.
It patches `app.asar` before extraction so the final AppImage includes the webview fixes.

To run the AppImage:
```bash
# Ensure codex CLI is in your PATH
./dist/Codex-1.0.0.AppImage
```
`bundle_linux.sh` will also bundle the CLI into the AppImage when `CODEX_CLI_PATH` is set or `codex` is found in your `PATH`. Otherwise, set `CODEX_CLI_PATH` before launching. 

### Linux (Patch app.asar)
If you want to patch the Linux build (for example, after extracting an AppImage), use:

```bash
./Codex-*.AppImage --appimage-extract
python3 scripts/patch_linux.py --asar squashfs-root/resources/app.asar
```

The script will back up the original `app.asar` and write a patched copy in place.

### Troubleshooting (Linux)
- If the AppImage reports it cannot locate the Codex CLI, make sure `codex` is on your `PATH` **or** set `CODEX_CLI_PATH` to an **absolute** path to the binary (not a directory). For example:

```bash
export CODEX_CLI_PATH=/usr/local/bin/codex
./dist/Codex-1.0.0.AppImage
```

- On WSL, ensure `CODEX_CLI_PATH` points to a Linux `codex` binary (not `codex.exe` or `.cmd` from Windows). If you installed the CLI via `npm i -g @openai/codex` inside WSL, the bundler will also search the npm global install for the Linux binary.

## Details

The scripts will:
- Extract the DMG to `work/`
- Build a platform-ready app directory
- Rebuild native modules (`better-sqlite3`, `node-pty`)
- (Windows) Launch Codex directly
- (Linux) Package as AppImage

## Notes
- This is not an official OpenAI project.
- Do not redistribute OpenAI app binaries or DMG files.
- The Electron version is read from the app's `package.json` to keep ABI compatibility.

## License
MIT (For the scripts only)
