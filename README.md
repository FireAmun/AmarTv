# AmarTv

A simple IPTV player from one Flutter codebase:

- **Windows** (main use): a laptop connected to a TV by HDMI. It has a TV mode with keyboard, remote-control and phone-remote control.
- **Android** phone: list browsing in portrait, fullscreen landscape player.

Features:

- Live channels from one playlist URL. If the M3U link is blocked (common with "Xtream Codes" panels), it automatically logs in through `player_api.php`.
- TV guide (now/next) on the channel banner and in the list, when the provider supplies guide data.
- Subscription status: expiry date and connections, with a warning before it expires.
- First-run "choose your groups" screen, favorites in your own order, and favorite quick numbers.
- Picture zoom: fit / fill / stretch.
- Series (seasons and episodes) and movies, with resume where you stopped.
- Remote-control and media keys, and your phone as a remote over Wi-Fi.
- Auto-reconnect, offline cache, parental PIN, sleep timer, two playback profiles.

---

## Install from a flash drive (the easy way)

Build the kit once on the development PC:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build_usb_kit.ps1
```

Copy **`dist\USB-Kit`** to the flash drive. It contains:

| File | Use |
|---|---|
| `AmarTv-Setup.exe` | Windows installer. No admin rights; installs to `%LOCALAPPDATA%\Programs\AmarTv` with Start-menu and desktop shortcuts. It picks up the `config.json` next to it, so the app starts ready to watch. |
| `AmarTv.apk` | Android app. If `config.json` exists in the project root, this is a **personal build** with your playlist inside, so phones need no setup. |
| `AmarTv-portable\` | Runs straight from the drive without installing (double-click `AmarTv.exe`). |
| `config.json` | Your playlist URL (copied from the project root). |
| `READ ME FIRST.txt` | The steps below, for whoever installs it. |

**Each Windows PC:** double-click `AmarTv-Setup.exe` → Install. If SmartScreen says "Windows protected your PC", click *More info → Run anyway* (the app isn't from the Store or code-signed).

**Each Android phone:** copy `AmarTv.apk` to the phone (cable, Drive, Telegram…), tap it, and allow "install from this source" the first time. If Play Protect warns, choose "Install anyway". Open AmarTv and the channels are there.

**Updating:** run the new setup or install the new APK over the old one. Favorites and settings stay.

> The kit and the personal APK contain your IPTV login. Keep the drive private and don't share the APK. `config.json`, `dist/` and `build/` are git-ignored.

---

## 1. Development setup

- Flutter stable (tested with 3.32.8 / Dart 3.8).
- Windows builds: Visual Studio 2022 Build Tools with "Desktop development with C++", and Windows Developer Mode on.
- Android builds: Android SDK 35 and JDK 17. Run `flutter doctor --android-licenses` once.
- Installer: Inno Setup 6 (`winget install JRSoftware.InnoSetup --scope user`).

```powershell
flutter pub get
flutter test
flutter run -d windows
```

### Playlist URL (secret, never in git)

The app reads `config.json`:

- Windows: next to `AmarTv.exe`.
- Android: inside the app. Enter it in Settings, or use a personal APK.
- Project root: used by `build_usb_kit.ps1` for the kit and the personal APK.

```json
{
  "playlistUrl": "http://example.com/get.php?username=USER&password=PASS&type=m3u&output=ts",
  "userAgent": ""
}
```

Usernames and passwords are shown as `***` in logs and error messages.

## 2. Other build commands

```powershell
scripts\package_portable.ps1          # dist\AmarTv-portable-win64.zip (no config, no data)
flutter build apk --release           # generic APK (asks for the URL on first start)
```

`package_portable.ps1` copies only the exe, its DLLs and Flutter's own `data\` files, plus the VC++ runtime DLLs. It refuses to package configs, databases, settings, logs, keystores or old executables.

### Android release signing (optional)

Create a keystore outside the project:

```powershell
keytool -genkey -v -keystore C:\Users\<you>\keys\amartv.jks -keyalg RSA -keysize 2048 -validity 10000 -alias amartv
```

Then add `android\key.properties` (it is git-ignored):

```properties
storePassword=...
keyPassword=...
keyAlias=amartv
storeFile=C:\\Users\\<you>\\keys\\amartv.jks
```

Without it, release APKs use the debug key, which is fine for personal sideloading.

## 3. Connect to the TV (HDMI)

1. Press **Win + P** and choose **Duplicate** or **Second screen only**.
2. Sound: click the taskbar speaker icon and choose the TV / HDMI output, then switch channel once.
3. **TV mode** (Settings, on by default) starts fullscreen and plays the last channel with large text.

### Keys (keyboard, remote controls, air mice)

| Key | Action |
|---|---|
| ↑ / ↓, Channel +/−, Next/Prev track | change channel (in the list: move) |
| ← / → | volume; in movies: seek −10 s / +30 s; in the list: change group |
| + / − | volume |
| Enter / OK | open the list / play the selected channel |
| Esc / Back | close the list / leave fullscreen |
| Backspace | last channel |
| 0-9 | channel number (or favorite number, see Settings) |
| Tab / Menu | show or hide the list |
| Space / Play-Pause | pause a movie or episode |
| F | fullscreen |
| M | mute |
| Z | zoom: fit / fill / stretch |
| I / Info | show the channel banner with the guide |
| S | series |
| Ctrl+F | search |
| Shift+↑/↓ | move a favorite (Favorites list) |

### Phone as a remote

1. On the PC: **Settings → Phone remote → On**. Note the 4-digit code. If Windows asks, allow AmarTv on **Private networks**.
2. On the phone (same Wi-Fi): tap the remote icon at the top of AmarTv. The PC shows up automatically; tap it, enter the code, then Connect.

## 4. Troubleshooting

- **Stutter**: switch to Settings → Playback → **Compatibility**. Use cable or 5 GHz Wi-Fi, and keep the laptop plugged in.
- **No sound on the TV**: choose the HDMI output in Windows, then switch channel.
- **"Access denied (403)"**: your subscription allows **1 connection** (see Settings → Subscription). Stop playback on other devices first.
- **No TV guide**: the provider has to supply guide data. Yours currently doesn't (only 1 of 6,386 channels has a guide ID).
- **The list won't load**: check the URL in Settings. The app tries M3U first, then the Xtream API. You can also try a `userAgent` in `config.json`.
- **Phone remote can't find the PC**: same Wi-Fi? Phone remote on? Allowed in the firewall? Otherwise type the PC address shown in Settings.
- **Logs** (passwords hidden): `data\amartv\logs\amartv.log` in the app folder.

## Project layout

```
lib/
  core/            paths, config.json, logging + URL masking, backoff, db (drift), theme
  features/
    playlist/      M3U parser (isolate), Xtream fallback, playlist/favorites/history state
    xtream/        player_api client: account, EPG, series (+ pure parsers)
    channels/      filtering, list widgets, group setup
    player/        PlayerController (one player, reconnect, stall detection, VOD resume), view
    series/        series and episodes pages
    remote/        phone-remote server (PC) and remote page (phone)
    settings/      settings model + page
    home/          desktop (Windows/TV) and phone layouts
installer/amartv.iss          Inno Setup script
scripts/build_usb_kit.ps1     everything for the flash drive
scripts/package_portable.ps1  portable zip
tool/make_icon.dart           regenerates assets/icon/*.png
```
