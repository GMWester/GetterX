# GetterX

Automatically download, update and install releases from **GitHub, GitLab, Codeberg/Forgejo/Gitea, Bitbucket, SourceForge, Modrinth, CurseForge, Hangar (PaperMC), SpigotMC, Thunderstore, itch.io, F-Droid, IzzyOnDroid, PyPI — and any website**.
Like Obtainium, but for every platform and with more modes:

* **Latest only**: keep one up-to-date copy (auto-update apps; opens the APK installer on Android).
* **Every new release**: from now on, download each new release into its own folder; keep or delete the old ones (optionally keep the last *N*).
* **Every release ever**: download a repo's complete release history, then keep it complete.
* **Latest per mod loader & game version** (Modrinth / CurseForge): e.g. the newest Fabric, Forge and NeoForge builds for 26.3, for 26.2, for 26.1.x, … Older builds for the same game version are ignored, and when a newer build appears, the old file is replaced (or kept, if you prefer).

Per source you choose:
* the **download folder** (e.g. one repo in `C:\repo`, a mod in `D:\lol\here`),
* **which files**: pick them from the latest release (remembered for future versions), file types (only `.exe`, only `.jar` …), only files for this device, regex include/exclude,
* **which versions**: release / beta / alpha, only Fabric (or any loaders), only certain game versions or the newest *N*, a version/tag regex.

Optional sign-in for private GitHub repos, purchased itch.io games and private Modrinth projects. See [SECURITY.md](SECURITY.md).

### Installing updates automatically
* **Android**: per source, "Install updates automatically". On Android 12+ updates of apps GetterX installed happen silently; otherwise Android asks once. GetterX reads the installed version and shows *Up to date / Update available / Installed version is newer / Not installed*, refuses APKs signed with a different key and never downgrades automatically.
* **Windows / macOS / Linux** (opt-in per source): `.msi`, Inno/NSIS/WiX `.exe`, `.msix`; `.dmg`/`.zip` apps copied to Applications, `.pkg`; AppImage, `.deb`, `.rpm`, `.flatpak`.
* Optional **VirusTotal** check (hash lookup only) before installing; flagged files are not installed.
* Notifications for new versions, finished installs and problems.

### Finding things
* **Search** Modrinth, CurseForge, Hangar, SpigotMC, GitHub, GitLab and Codeberg at once — mods, modpacks, resource packs, shaders, data packs, plugins, repositories.
* **Also available on**: each source shows where else the same project is published — CurseForge ↔ Modrinth (exact SHA-1 match where possible, otherwise slug + name), the project's GitHub/GitLab source code, F-Droid/IzzyOnDroid by package id. Track it there too, or switch over keeping settings and files.
* **Import from device** (Android): finds F-Droid / IzzyOnDroid sources for your installed apps. **Import** GetterX backups, Obtainium/ObtainX exports or plain lists of links.

### Organising
Folders (categories) with filters and grouping, pin to top, *needs attention* first, search/sort, *track only* (notify, no download), *on demand only*, skip a version, stop a running download, configurable swipe actions with undo, two-pane layout on wide screens, icons with per-app colours, Material You / custom accent colour, neutral or tinted backgrounds, Light / Dark / OLED black.

## Platforms

| Platform | Download (from the latest release) |
|---|---|
| Windows 10/11 x64 | `GetterX-windows-x64-setup.exe` (choose **Install** or **Portable** in the installer) · `GetterX-windows-x64-portable.zip` |
| Windows on ARM | `GetterX-windows-arm64-setup.exe` · `GetterX-windows-arm64-portable.zip` |
| macOS 10.15+ (Intel & Apple Silicon) | `GetterX-macos.dmg` / `GetterX-macos.zip` · `GetterX-macos-portable.zip` |
| Linux x64 / ARM64 | `GetterX-linux-<x64\|arm64>.AppImage` · `.deb` · `-portable.tar.gz` · installer: `curl -fsSL https://github.com/gmwester/GetterX/releases/latest/download/getterx-install.sh \| sh` |
| Android 7+, Android TV, Android XR | `GetterX-android-arm64-v8a.apk` (most devices), `-armeabi-v7a` (**32-bit ARM**), `-x86_64`, `-universal` |
| iOS | `GetterX-ios-unsigned.ipa` (sideload with AltStore / SideStore / your own certificate) |

### GetterX Lite (32-bit and other older systems)

Same features (sources, modes, folders, filters, themes), but the interface opens **in your web browser**.
For systems the desktop app cannot run on:

| System | Download |
|---|---|
| Windows 32-bit (x86) | `GetterX-Lite-windows-x86.zip` → run `GetterX Lite.cmd` |
| Linux 32-bit x86 | `GetterX-Lite-linux-x86.tar.gz` → run `getterx-cli` |
| Linux 32-bit ARM (e.g. Raspberry Pi OS 32-bit) | `getterx-cli-linux-arm` |
| Linux RISC-V | `getterx-cli-linux-riscv64` |
| Any other system / servers | `getterx-cli-<os>-<arch>` |

Starting it without arguments opens the page; `getterx-cli serve --no-browser` prints the private link instead (e.g. on a headless box). Lite reads logins from environment variables only.
It listens on 127.0.0.1 only and every request needs the random key in the printed link.

Not possible: 32-bit x86 Android, Android 6 and older, Windows 7/8 for the desktop app (Flutter no longer supports them; use Lite where it runs).

**Themes**: Auto, Light, Dark and **OLED black** (pure black backgrounds), in the app and in Lite.

**Portable mode**: if a `portable.txt` file sits next to the program, all settings are stored in `GetterX-Data` and downloads go to `GetterX-Downloads` next to it.

**Self-update** (optional): Settings → *GetterX updates*. Either update automatically, or get an *Update now* button. Updates are verified with SHA-256 before installing.

**Background checks**: Android/iOS use the system scheduler; on Windows/macOS/Linux GetterX registers a scheduled task (Task Scheduler / launchd / systemd timer) that checks without opening a window.

## Command line

```
getterx-cli add https://modrinth.com/mod/sodium --dir "D:\mods" --loaders fabric,neoforge
getterx-cli add https://github.com/owner/repo --mode allReleases --keep-old
getterx-cli check
getterx-cli list
```
Credentials for the CLI come from `GETTERX_GITHUB_TOKEN`, `GETTERX_CURSEFORGE_KEY`, `GETTERX_ITCH_KEY`, `GETTERX_MODRINTH_TOKEN`.

## Building / releasing

Branches: `main` holds everything. `platform/android`, `platform/ios`, `platform/windows`, `platform/macos`, `platform/linux` and `platform/lite` build and test only that platform; CI merges `main` into them automatically after every push to `main`.

* `flutter run` (app), `cd packages/getterx_core && dart test` (engine tests).
* CI (`.github/workflows/build.yml`) builds every platform on every push.
* **Releasing**: bump `version:` in `pubspec.yaml` and push to `main`. CI creates **one** release `v<version>` containing all platforms. Pushing without a version bump never creates a release.
* Android release signing uses the repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Without them CI refuses to publish.
* "Sign in with GitHub" needs an OAuth app client id (Device flow enabled): build with `--dart-define=GITHUB_CLIENT_ID=...` or enter it in Settings → Advanced. Token sign-in works without it.

## License

AGPL-3.0, see [LICENSE](LICENSE).
