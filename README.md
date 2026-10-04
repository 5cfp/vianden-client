# vianden-client

Official desktop client for **Project Vianden** (code name), a self-hosted chat platform with text and voice channels.
Built with Flutter. Windows first.

> Status: early development (milestone M0). Not usable yet.

## Requirements
- Flutter (stable) with Windows desktop support (`flutter doctor` should show Visual Studio ✓)

## Run
```powershell
flutter pub get
flutter run -d windows
```

## Try it with a local server
1. Start the server (see the `vianden-server` README): `go run ./cmd/server`
2. Run the client: `flutter run -d windows`
3. Enter `http://127.0.0.1:8080` and press **Connect**.
4. **First account (owner):** choose **Register** and use the setup token (`vo_...`) printed in the server console as the invite code.
5. As the owner, open the **⋯** menu (bottom left) › **Invite a friend** and give the code to a friend; they register with it.
6. Chat in **General**. The owner can add rooms with **+** and rename or delete them with the **⋮** menu. Messages, room changes, "… is typing" and the online count update **live** (WebSocket); if the connection drops, the app shows "Reconnecting…" and reconnects by itself. Enter sends; Shift+Enter adds a line.

The app remembers the server and your login (the session token is stored encrypted with the OS secure storage; on Windows via DPAPI). **Log out** ends the session on the server too.

Addresses without `http://` or `https://` use **https** by default.

## Release build (Windows)
```powershell
.\scripts\build-windows.ps1
```
Runs the tests, builds the release, and writes `dist\vianden-client_<version>_windows_x64.zip` plus its SHA-256. Friends unzip it and run `vianden_client.exe` (no installer). The app is not code-signed yet, so SmartScreen may warn: **More info → Run anyway**.

## Self-signed servers (trust on first use)
For servers without a domain, the app shows the certificate's fingerprint once; compare it with the one the server owner gives you. The app remembers it and warns if it ever changes.

## Tests
```powershell
flutter test
```

## License check
This project only allows permissive dependency licenses. Run this whenever dependencies change (`pubspec.yaml`):
```powershell
dart pub global activate very_good_cli   # once
very_good packages check licenses --dependency-type=direct-main,transitive --allowed=MIT,BSD-2-Clause,BSD-3-Clause,Apache-2.0,ISC,Zlib,Unlicense,PostgreSQL
```
If `very_good` is not found, add `%LOCALAPPDATA%\Pub\Cache\bin` to your PATH.

## Project layout
| Folder | What it contains |
|---|---|
| `lib/app_config/` | **All** branding and theme values (app name, colors, default server). Widgets never hardcode these. |
| `lib/core/` | Code shared by all features: API client, live connection (WebSocket), data models, session state (Riverpod), secure storage |
| `lib/widgets/` | Small reusable widgets |
| `lib/features/` | One folder per screen/feature: `connect/`, `auth/` (login + register), `chat/` (rooms, messages, composer, owner room tools) |
| `test/` | Tests, mirroring `lib/` |

## License
MIT, see [LICENSE](LICENSE).
