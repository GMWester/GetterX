# GetterX security

GetterX can sign in to GitHub, itch.io, Modrinth and CurseForge. This file
describes how those logins are protected and what was audited.

## Reporting a vulnerability

Please open a private advisory: *Security → Report a vulnerability* on
<https://github.com/gmwester/GetterX>. Do not post tokens or logs with tokens in public issues.

## How credentials are handled

| Threat | Protection | Where |
|---|---|---|
| Token stolen from disk / backups | Tokens and API keys are stored only in the OS credential store (Android Keystore-backed encryption, iOS/macOS Keychain with `first_unlock_this_device` = never synced to iCloud, Windows Credential Manager/DPAPI, Linux Secret Service). `config.json` contains **no secrets** (tested). Android backups and device-transfer of app data are disabled. | `lib/app/secure_credentials.dart`, `AndroidManifest.xml`, `data_extraction_rules.xml` |
| Password theft | itch.io passwords are sent once, over HTTPS, to `api.itch.io` and never stored; the field is cleared right after use. GitHub sign-in uses the OAuth device flow, so GitHub passwords never touch GetterX. 2FA (TOTP) is supported. | `packages/getterx_core/lib/auth.dart`, `lib/ui/accounts_page.dart` |
| Token sent to the wrong server | Every credential is pinned to an exact HTTPS host: GitHub → `api.github.com`, Modrinth → `api.modrinth.com`, CurseForge → `api.curseforge.com` (never to a custom/mirror API URL), itch.io → `api.itch.io`. Asset URLs returned by an API get the token only if they point at that same host (tested with a malicious asset URL). Website / GitLab / Forgejo / F-Droid sources never receive any credential. | `credentials.dart` (`mayReceiveCredential`), sources |
| Token leaked through redirects | Downloads follow redirects manually: headers with credentials are sent only to the original host and are dropped when GitHub/itch.io redirect to their CDNs (tested). | `downloader.dart` |
| Downgrade / man-in-the-middle | HTTPS only for every API call and download, including after redirects (an `https → http` redirect is refused; tested). Certificates are always validated (no custom trust callbacks). If the operating system's root store rejects a site (common on Windows, which installs roots lazily), GetterX retries once against Mozilla's root list bundled with the app; an untrusted certificate still fails (tested). Android blocks cleartext traffic. | `downloader.dart`, `tls.dart`, `source.dart`, manifest |
| Token leaked in logs / error messages | All errors, the activity log and "last error" texts go through `redact()`, which removes `api_key=`/`token=`/`Bearer …`/GitHub token patterns and the actual stored secret values (tested). | `credentials.dart` |
| Phishing via device code | The sign-in dialog shows the code and warns to approve only a sign-in you started. Tokens are verified against the real service before being saved. | `accounts_page.dart` |
| Over-privileged tokens | The UI recommends fine-grained, read-only tokens (GitHub "Contents: read" on selected repos, Modrinth "read user data/projects/versions"). Note: the classic OAuth device flow needs the `repo` scope for private repos; prefer a fine-grained token if you want read-only. | `accounts_page.dart` |
| Sign-out | Sign-out deletes the secret from the credential store. Revoke the token on the service as well (links shown). | `accounts_page.dart` |
| CLI | The command-line tool never stores secrets; it only reads `GETTERX_*` environment variables. | `bin/getterx_cli.dart` |
| Portable mode | Settings travel with the folder, credentials do not (they stay in the machine's credential store). | `paths.dart` |

## Automatic installs

* Off by default, per source. Android uses the system PackageInstaller: silent only where Android allows it (updates of apps GetterX installed, Android 12+); APKs whose signing certificate differs from the installed app, or that would downgrade it, are never installed automatically.
* Desktop installers run only for sources where you enabled it, with arguments passed directly (no shell). Unknown `.exe` installers are opened normally instead of being run silently.
* Optional VirusTotal lookup before installing: only the SHA-256 is sent, with your key, to `www.virustotal.com`; flagged files are not installed.

## Other hardening

* **Path traversal**: remote file names are sanitised and every destination is checked to stay inside the source's folder (tested with `../`, absolute, Windows device names).
* **Hostile web pages**: the website scanner is linear-time and capped at 4 MB per page (tested with a pathological page).
* **Self-update integrity**: GetterX updates only from `github.com/gmwester/GetterX`, without using your GitHub token, and refuses to install an update whose SHA-256 digest (published by GitHub) is missing or does not match. Android additionally refuses updates not signed with the same release key. Update helper scripts quote all paths.
* **Release signing**: CI refuses to publish a release with debug-signed APKs and verifies the APK certificate before publishing; key material is deleted from the runner after the build.
* **Dependencies**: CI checks every locked dependency against the OSV.dev vulnerability database on each push and fails on known vulnerabilities (`tool/osv_check.py`).
* **Background tasks** never receive secrets as task parameters; they read them from the credential store.

## Known limitations

* Anyone with access to your unlocked user account can use the stored tokens (as with any app that keeps you signed in).
* macOS/Windows builds are not notarized/code-signed by a paid certificate; verify downloads with `SHA256SUMS` from the release.
* iOS builds are unsigned (for sideloading); background refresh timing is decided by iOS.
