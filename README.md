# Cloud IPTV

IPTV player built with Flutter. Windows is the tested platform; Linux, Android
and iOS are in development. Flutter,
`media_kit` (libmpv), drift (SQLite) and Riverpod. Supports M3U playlists,
Xtream Codes and XMLTV guides.

## Setup

    flutter pub get
    dart run build_runner build --delete-conflicting-outputs
    flutter run

Linux also needs `libmpv-dev`. Building on Windows needs Developer Mode
(`start ms-settings:developers`) and Visual Studio with the C++ workload.

## Windows packaging

`scripts\build_windows_installer.bat` builds the release and produces
`build\installer\CloudIPTV_Setup.exe`. It needs Inno Setup 6
(`winget install JRSoftware.InnoSetup`), or set `ISCC` to its compiler path.

For an MSIX package: `dart run msix:create`, which writes
`build\windows\x64\runner\Release\CloudIPTV.msix`. Without a certificate it is
signed with a self-signed test certificate, so set `certificate_path` and
`certificate_password` under `msix_config` for real deployments.

## Tests

    flutter test
    flutter test integration_test/player_test.dart -d windows

The second drives the real libmpv against a local server, covering playback,
retry, failover, stalls and dropped connections. It takes about 2 minutes.

## Layout

    lib/models     entities shared by every backend (also the drift row classes)
    lib/services   M3U and XMLTV parsers, Xtream client, database, sync
    lib/providers  Riverpod state
    lib/player     libmpv tuning, retry and failover, video widget
    lib/ui         screens

## Website

The site at https://imzondax.github.io/cloud-iptv/ is served from `docs/`.

## Content

Cloud IPTV is only a player. It includes no channels or video, and you add
sources you have the right to use.

## Credits

- This product uses the TMDB API but is not endorsed or certified by TMDB.
- Inter and Space Grotesk are licensed under the SIL Open Font License; see
  `assets/fonts/`.
- `integration_test/fixtures/sample.ts` is an excerpt of Big Buck Bunny,
  (c) Blender Foundation, licensed under CC BY 3.0, https://peach.blender.org.
