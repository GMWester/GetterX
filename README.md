# GetterX

Automatically download and update releases from **GitHub, GitLab, Codeberg/Forgejo/Gitea, Modrinth, CurseForge, itch.io, F-Droid — and any website**.
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

## Platforms

| Platform | Download (from the latest release) |
|---|---|
| Windows | `GetterX-windows-x64-setup.exe` (choose **Install** or **Portable** in the installer) · `GetterX-windows-x64-portable.zip` |
| macOS | `GetterX-macos.dmg` / `GetterX-macos.zip` · `GetterX-macos-portable.zip` |
| Linux | `GetterX-linux-x64.AppImage` · `GetterX-linux-x64.deb` · `GetterX-linux-x64-portable.tar.gz` · installer: `curl -fsSL https://github.com/gmwester/GetterX/releases/latest/download/getterx-install.sh \| sh` |
| Android, Android TV, Android XR | `GetterX-android-arm64-v8a.apk` (most devices), `-armeabi-v7a`, `-x86_64`, `-universal` |
| iOS | `GetterX-ios-unsigned.ipa` (sideload with AltStore / SideStore / your own certificate) |
| CLI (servers, scripts) | `getterx-cli-*` |

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

* `flutter run` (app), `cd packages/getterx_core && dart test` (engine tests).
* CI (`.github/workflows/build.yml`) builds every platform on every push.
* **Releasing**: bump `version:` in `pubspec.yaml` and push to `main`. CI creates **one** release `v<version>` containing all platforms. Pushing without a version bump never creates a release.
* Android release signing uses the repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Without them CI refuses to publish.
* "Sign in with GitHub" needs an OAuth app client id (Device flow enabled): build with `--dart-define=GITHUB_CLIENT_ID=...` or enter it in Settings → Advanced. Token sign-in works without it.

## License

AGPL-3.0, see [LICENSE](LICENSE).
