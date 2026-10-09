# OBSBOT Nacelle

[English](#english) · [Français](#francais)

<a id="english"></a>

## English

Remotely control the gimbal of an OBSBOT Tiny 2 from an iPhone.

The camera is plugged over USB into a Mac that already streams it with [go2rtc](https://github.com/AlexxIT/go2rtc), and to HomeKit through Homebridge. HomeKit cannot drive a pan/tilt/zoom: this project adds what is missing.

> Personal project, not affiliated with OBSBOT.

### Status

- **Mac side**: the **PTZBot for Mac** app, which contains `ptzd`, installs from the disk image of the published releases (see "Installing PTZBot for Mac"), then updates itself. It can also be built from source with `scripts/install-mac.sh`. The OBSBOT SDK is then installed from the app, which compiles `obsbot-ai` on the Mac.
- **iOS app** (PTZBot): installs from Xcode onto the iPhone (see "iOS app" below).

Design: [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [local access spec](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [discovery and QR code spec](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [Mac app spec](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [ptzd in the app spec](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [distribution spec](docs/superpowers/specs/2026-10-08-distribution-design.md) · [Mac side plan](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [iOS app plan](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [local access plan](docs/superpowers/plans/2026-10-06-acces-local.md) · [discovery and QR code plan](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [Mac app plan](docs/superpowers/plans/2026-10-06-app-mac.md) · [feasibility tests](docs/spike/2026-10-05-faisabilite.md). The design documents are in French.

### Architecture

```
iPhone: SwiftUI app                          Mac (the go2rtc one)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ Joystick, zoom,           │            │ PTZBot.app ▸ ptzd (child)        │
│ privacy, video offer ─────┼─ WebSocket▶│   ├─ UVC commands ──▶ Tiny 2     │
│                           │ authentic. │   ├─ runs obsbot-ai (SDK)        │
│                           │◀─ state ───│   └─ relays the offer ┐          │
│                           │            │                       ▼          │
│ WebRTC video ◀────────────┼─ frames ───│ go2rtc (local API) ◀── ffmpeg    │
└───────────────────────────┘            └──────────────────────────────────┘
   at home: Wi-Fi (Bonjour, local address); away: the same address through Tailscale
```

- **`ptzd`**: a Swift service, stored inside the app (`PTZBot.app/Contents/Helpers/ptzd`) and started by it: it only runs while PTZBot is open, and stops by itself if the app goes away, even when force-quit. PTZBot restarts it if it stops unexpectedly. It is the only one sending gimbal commands to the camera, over UVC. It listens on the Mac's Tailscale address, on 127.0.0.1, and on its Wi-Fi and Ethernet interfaces, where it advertises itself over Bonjour (`_nacelle._tcp`). Each iPhone is paired once, on the local network, by scanning the QR code shown by the Mac app (or `ptzd pair`); after that, it signs a challenge on every connection. On the local network, everything also goes through a TLS channel: during pairing, its key is the QR code's secret; afterwards, a key specific to each iPhone, handed over at pairing. Only connections from 127.0.0.1 skip the challenge.
- **`obsbot-ai`**: a small helper that turns the camera's AI tracking on or off with the OBSBOT SDK. `ptzd` sends it an order at the first joystick move (tracking would fight the moves), when entering privacy mode and on the apps' request. Loading the SDK takes about 4 seconds, so `ptzd` runs `obsbot-ai serve`, a resident mode: the SDK stays loaded, `on` and `off` are read from the standard input, one per line, and answered with `obsbot-ai: ready`, then `obsbot-ai: ok` or `obsbot-ai: err <code>` for each order, so an order takes effect within a few milliseconds. `ptzd` starts it when a client controls the camera (an iPhone authenticating, or any message from a client), stops it after 10 minutes without activity and when the camera is plugged or unplugged, and it exits by itself when its input closes, hence also if `ptzd` dies. The first order after opening the app can still take a few seconds. The one-shot modes `obsbot-ai on` and `obsbot-ai off` remain, for manual use. PTZBot compiles it on the user's Mac, from its source shipped in the app (`Contents/Resources/obsbot-ai.cpp`) and the SDK headers, with Apple's developer tools; it lives next to the SDK, in `~/Library/Application Support/ObsbotNacelle/sdk/`, and `ptzd` runs it with `DYLD_LIBRARY_PATH` pointing there. Neither the SDK nor `obsbot-ai` is in the app or the disk image: the SDK license does not allow redistribution.
- **PTZBot for Mac**: a menu bar app that starts `ptzd` and talks to it over 127.0.0.1: QR code pairing, paired devices and connected clients, kicking out, privacy and AI tracking (see "Mac app" below). It updates itself with [Sparkle](https://sparkle-project.org).
- **go2rtc**: `ptzd` relays the app's WebRTC offer to it; the frames then go straight from go2rtc to the iPhone. See "go2rtc" below to close it to the local network.

### Installing PTZBot for Mac

Requirements:

- an Apple silicon Mac running macOS 15 or later;
- Tailscale on the Mac to control the camera away from home (without it, `ptzd` only listens on 127.0.0.1 and on the local network);
- OBSBOT Center closed: when open, it skews the tilt readback;
- for AI tracking only: the OBSBOT SDK, to request at [obsbot.com/sdk](https://www.obsbot.com/sdk), and Apple's developer tools (PTZBot offers to install them).

Then:

1. Download `PTZBot-X.Y.Z.dmg` from the [releases page](https://github.com/Djoko-cli/obsbot-nacelle/releases), open it and drag **PTZBot** into **Applications**.
2. **First launch (Gatekeeper).** PTZBot is signed but not notarized: the first time, macOS refuses to open it. Open **System Settings › Privacy & Security**, click **Open Anyway** next to the message about PTZBot, and confirm. This is needed only once.
3. On first launch:
   - **Previous installation.** If the launchd agent `io.github.djoko-cli.obsbot-nacelle.ptzd` from an earlier version is there, PTZBot offers to replace it. **Replace** stops it, renames its plist to `.plist.bak`, moves the old binaries in `bin/` to the Trash and takes over the SDK in `lib/`. Paired iPhones and settings are kept. **Later** keeps the old `ptzd` (the panel shows "Previous installation"); the question comes back at the next launch.
   - **`config.json`.** If it is missing, PTZBot creates it with the Mac's Tailscale address, or on 127.0.0.1 only without Tailscale (the panel says so).
   - **Permissions.** macOS asks for local network access for PTZBot (`ptzd` depends on it): answer **Allow**. At the iPhone's first connection, it may also ask whether `ptzd` may accept incoming connections: answer **Allow**. The question may come back after an update, because the binary changes.
4. **OBSBOT SDK.** In the panel, **OBSBOT SDK › Install SDK…**: choose the `.zip` archive received from OBSBOT or its unzipped folder. A lone `libdev.dylib` is refused: the headers are needed to compile `obsbot-ai`. PTZBot takes `macos/arm64-release/libdev.dylib` and the `include/` folder next to `macos/`; the other copies of the library in the archive are listed and ignored. The window shows the architecture, the signature, the origin and the quarantine; **Allow This SDK** copies the library and the headers into `sdk/`, removes the quarantine from these copies only, compiles `obsbot-ai` with Apple's developer tools, then checks that it loads the SDK. Everything happens in one go: if any step fails, the previous SDK and `obsbot-ai` are kept, and the compiler output goes to `obsbot-ai-compilation.log`. Without the SDK, everything works except AI tracking.
   - **Developer tools.** Without them, the panel's SDK line and the **OBSBOT SDK** window offer **Install Developer Tools…** before any choice of SDK. The button starts Apple's installation (`xcode-select --install`), only when you click it: accept in Apple's window, then reopen the panel, or click **Check Again** in the window. An SDK already installed whose `obsbot-ai` must be recompiled shows "Tools required", with the same button.
   - **SDK installed by an earlier version.** An SDK copied without its headers (a single `libdev.dylib`) shows "Incomplete", with "Reinstall the SDK from its archive or folder: its headers are missing." under it: reinstall it from the archive.

### Updates

- PTZBot checks for updates at launch and every 24 hours, on the `mac/app/appcast.xml` feed of this repository. Each release is signed with an Ed25519 key, checked before the update is even unpacked (`SUVerifyUpdateBeforeExtraction`): Sparkle refuses a badly signed one, whatever its code signature.
- An update downloads silently and installs when the app quits, or right away with **Install and Relaunch**. PTZBot first stops `ptzd`, as with **Quit**.
- **Check for Updates…** is in the panel; **Settings…** has **Check automatically** and **Install automatically** (both on by default), **Open at login** and the version.
- After an update, if the `obsbot-ai` source changed, PTZBot recompiles it at launch ("Recompiling…") without asking anything. If the tools are missing or the compilation fails, the previous `obsbot-ai` stays in use and the panel says so.
- Builds made from source (build number 1, as with `scripts/install-mac.sh`) never look for updates.

### Building from source

Requirements: Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The OBSBOT SDK is no longer needed to build the app.

```bash
scripts/install-mac.sh
```

The script builds the app (`ptzd` in `Contents/Helpers`, the `obsbot-ai` source in `Contents/Resources`, Sparkle in `Contents/Frameworks`), quits the running app, installs it into `~/Applications/PTZBot.app` and launches it. It touches neither launchd nor the files in `~/Library/Application Support/ObsbotNacelle/`. Such a build keeps build number 1: Sparkle never starts in it. Keep a single copy of PTZBot: to go back to the published releases, move `~/Applications/PTZBot.app` to the Trash and install the disk image.

`mac/app/check-bundle.sh` checks a Release build: `ptzd`, the `obsbot-ai` source and Sparkle are present; the SDK, its headers and any `obsbot-ai` binary are absent.

Publishing a release (maintainer): write its section in `NOTES-VERSIONS.md` (**English**, then **Français**), set `MARKETING_VERSION` in `mac/app/project.yml`, then run `outils/publier.sh X.Y.Z` from a clean, up-to-date `main`. If it stops halfway, resume from `gestes.txt` in the products folder, never by running the script again. `outils/publier.sh X.Y.Z --repetition FOLDER --url-base http://127.0.0.1:PORT …` rehearses everything without GitHub.

### Settings (`config.json`)

| Key | Role | Default |
|---|---|---|
| `listenAddress` | The Mac's Tailscale address, or 127.0.0.1 without Tailscale; created by PTZBot at first launch | required |
| `port` | WebSocket port | 1985 |
| `panMaxSpeed`, `tiltMaxSpeed` | Maximum UVC speeds (pan 1–80, tilt 1–120) | 40, 60 |
| `panDirection`, `tiltDirection` | Direction of each axis, +1 or -1 | +1, +1 |
| `aiPath` | Path of `obsbot-ai`, relative to `~/Library/Application Support/ObsbotNacelle` (or absolute); when PTZBot starts `ptzd`, `--ai` wins (`sdk/obsbot-ai`; the old `aiOffPath` key is read if this one is missing, unless it names `obsbot-ai-off`) | `bin/obsbot-ai` |
| `localNetwork` | Listening and Bonjour advertising on Wi-Fi and Ethernet | `true` |
| `go2rtcAPI` | go2rtc's local API, to relay the video | `http://127.0.0.1:1984` |
| `streamName` | Relayed go2rtc stream | `obsbot` |

After a change, restart the service: in the panel, turn **ptzd service** off and on again.

### Troubleshooting

| Need | Command |
|---|---|
| Service log | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
| SDK output | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
| `obsbot-ai` compilation | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai-compilation.log` |
| Read the camera position | `/Applications/PTZBot.app/Contents/Helpers/ptzd uvc get` |
| Paired devices | `/Applications/PTZBot.app/Contents/Helpers/ptzd devices` |
| See the Bonjour advertisement | `dns-sd -B _nacelle._tcp` (Ctrl-C to stop) |
| Talk to the service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"adminWatch"}' wait 2` |

For a build from source, the app is in `~/Applications/PTZBot.app`.

The Mac cannot reach itself through its Tailscale address: locally, use 127.0.0.1.

`ptzd pair`, `ptzd devices` and `ptzd revoke` remain usable from the command line with the app's binary; `ptzd pair` needs the service running, so PTZBot open. The `ptzd` log and command line stay in French.

### Mac app (PTZBot)

It lives in the menu bar (the Tiny 2 icon), without a Dock icon, in English, or in French on a Mac set to French. **Settings… › Language** chooses Automatic (system language), Français or English right away; Sparkle's update windows follow at the next launch. The iPhone only controls the camera while PTZBot is open: **Open at login** makes that the normal use. Its panel shows:

- the **ptzd service** switch, remembered from one launch to the next, and the state of `ptzd` ("Active", "Starting…", "Stopped", "Restarted after an unexpected stop (n)", "Not responding" with a link to its log) and of the camera. Beyond 5 stops in 2 min, PTZBot stops restarting `ptzd`: "ptzd keeps stopping: open the log". It does not restart it either if another `ptzd` is already running (`ptzd.lock` lock or 127.0.0.1 port taken: "Port 1985 is already in use…"), if `config.json` is invalid or if its arguments are refused;
- the **OBSBOT SDK** line, with a short state on the right ("Ready", "Missing", "Quarantined", "Incompatible", "Does not load", "Tools required", "Incomplete", "Recompiling…", "Compile failed", "obsbot-ai not found"), and under it, on the full width, what it means and **Install SDK…**, **Install Developer Tools…** or, when the SDK is ready, **Change…**; until the SDK is ready, **AI tracking** is greyed out ("OBSBOT SDK required"), unless a previous `obsbot-ai` is still in use;
- the **Privacy** and **AI tracking** switches (tracking shows the last order: the real state cannot be read, a gesture in front of the camera can change it);
- the connected clients, with **Kick Out**: the connection is cut and the device refused for 10 min (while `ptzd` runs), without losing its pairing;
- **Pair an iPhone…**: the QR code as an image, valid for 5 min; closing the window cancels it;
- **Devices…**: the paired devices, **Unblock** and **Remove…** (the device is removed and its connections cut right away);
- **Check for Updates…** on its own line, then **Settings…** (**Check automatically**, **Install automatically**, **Open at login**, the version, for example "PTZBot 1.0.0 (412)"; macOS may ask for approval in System Settings › General › Login Items) and **Quit**: stops `ptzd` (6 s at most), then the app.

If local network access is denied to PTZBot, the panel says so, with a button to the privacy settings: iPhones then only find the Mac through Tailscale.

The app goes through `ptzd`'s trusted connection (127.0.0.1): any program on the Mac can do the same.

Tests: `(cd mac/app/PTZBotKit && swift test)`; publication tools: `python3 -m unittest discover -s outils/tests`.

### iOS app

Requirements: Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), an Apple ID (a free account is enough), the Mac side installed, and Tailscale on the iPhone to control the camera away from home. The iOS app is still in French only.

Recording: the record button (between AI tracking and privacy) saves the received video and sound into Photos, as an MP4 (H.264 and AAC), until you stop it. The sound is recorded even when muted in the app. Entering privacy mode, losing the connection, sending the app to the background or running low on space stops the recording and saves it; in privacy mode the button stays greyed out. A tap on the video hides the controls for a clean picture (only the record button and its timer stay during a recording); another tap brings them back.

1. Set the signing team in a local setting, not versioned. Its identifier is the OU field of the "Apple Development" certificates in the keychain:

   ```bash
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | grep organizationalUnitName
   ```

   ```bash
   printf 'DEVELOPMENT_TEAM = %s\n' <identifier> > ios/Config/Local.xcconfig
   ```

2. Generate the project, then build and install onto the iPhone, plugged in or paired. `<UDID>` is its identifier, given by `xcrun devicectl list devices`:

   ```bash
   (cd ios && xcodegen)
   ```

   ```bash
   xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates
   ```

   ```bash
   xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
   ```

3. At first launch, iOS asks you to trust the developer: Settings › General › VPN & Device Management.
4. At first launch, PTZBot looks for the Mac on Wi-Fi ("Recherche du Mac à proximité…"): iOS asks for local network access, answer **Allow**.
5. Pair the iPhone, on the same network as the Mac: in PTZBot on the Mac, **Pair an iPhone…** shows a QR code (valid for 5 min, single use, 3 attempts). As a fallback, for example over SSH, `ptzd pair` shows it in the Terminal:

   ```bash
   /Applications/PTZBot.app/Contents/Helpers/ptzd pair
   ```

   Then, in the iPhone app, tap **Scanner le QR code** and aim at the Mac's screen (iOS asks for camera access). The iPhone's key stays in its Secure Enclave; the Mac keeps its public key and the secret of the local network's encrypted channel, in `devices.json` (mode 600). The app remembers the Mac's local address in Réglages › Adresse du Mac (repli).

   Updating from a version that asked for the Tailscale name: the "Adresse du Mac (repli)" field keeps it. To switch to the local address (which also works over 4G through the subnet route), clear this field and tap Enregistrer before scanning: the app will store the Mac's local address there.
6. Away from home, the app reaches that same address through Tailscale if a tailnet device publishes the local network (subnet routing) and if the iPhone accepts routes. Otherwise, put the Mac's Tailscale name in the field (the `DNSName` field, without the final dot, of `tailscale status --self --peers=false --json` on the Mac): the app reaches it through `ptzd`'s Tailscale listener, without TLS.

Removing an iPhone: in PTZBot on the Mac, **Devices…** › **Remove…**; its connections are cut right away, after a message telling it: a connected iPhone forgets its pairing and goes back to the pairing screen. An iPhone offline at that moment learns it at its next connection through Tailscale; on the local network, it is simply refused and shows "Mac injoignable": on it, "Oublier cet appairage", then scan a new QR code. From the command line, `ptzd devices` gives the start of its identifier, then `ptzd revoke <start>`; its already open connections then last until they end. From the iPhone, "Oublier cet appairage" also removes it from the Mac's list when it is connected.

With a free Apple account, the app expires after 7 days: redo step 2.

Tests: `(cd ios && xcodegen && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build)`.

### go2rtc

`ptzd` relays the video negotiation to go2rtc's API on 127.0.0.1: the API therefore no longer needs to be open to the network. Suggested configuration (in `go2rtc.yaml`, to adapt):

```yaml
api:
  listen: "127.0.0.1:1984"
rtsp:
  listen: ":8554"
  username: "<user>"
  password: "<password>"
webrtc:
  listen: ":8555"
ffmpeg:
  bin: /opt/homebrew/bin/ffmpeg   # full path: under launchd, PATH does not contain /opt/homebrew/bin
streams:
  obsbot:
    - exec:…   # camera video (H.264)
    - exec:…   # camera microphone (AAC, for HomeKit)
    - ffmpeg:obsbot#audio=opus   # the same sound in Opus, for PTZBot (WebRTC)
```

- go2rtc lets local clients (127.0.0.1) skip the RTSP password: `exec:` sources that publish to `{output}` keep working unchanged.
- A network RTSP client, such as Homebridge, must then give the user and password in the stream address: `rtsp://<user>:<password>@<Mac>:8554/obsbot`.
- WebRTC port 8555 stays open: without an offer negotiated by `ptzd`, it gives no image.
- Sound in PTZBot: WebRTC does not carry AAC. The `ffmpeg:obsbot#audio=opus` source converts it to Opus as soon as PTZBot is open, even muted (the button only stops playback, so that sound comes back immediately). Without the `ffmpeg: bin:` line, go2rtc started by launchd does not find `ffmpeg` and the audio track stays silent, with no error message.
- `go2rtc.yaml` holds the RTSP password: set it to mode 600 (`chmod 600 go2rtc.yaml`).
- The RTSP stream to Homebridge, credentials included, travels in clear on the local network: a device intercepting this traffic can read them, as well as the images.
- The pairing QR code (PTZBot for Mac window, or `ptzd pair` and the URL shown under it) allows pairing a device for 5 minutes: only show it while scanning.
- Never expose 127.0.0.1:1985 to the network, for example with `tailscale serve` or `ssh -L`: connections from 127.0.0.1 skip authentication, any remote client coming through there would control the camera.

### Uninstalling

In PTZBot for Mac, **Settings…** › uncheck **Open at login**, then **Quit** (`ptzd` stops with the app), and move `/Applications/PTZBot.app` (or `~/Applications/PTZBot.app` for a build from source) to the Trash.

The data stays in `~/Library/Application Support/ObsbotNacelle/` (settings, paired iPhones, SDK, its headers and `obsbot-ai`) and the logs in `~/Library/Logs/obsbot-nacelle/`, until you delete them:

```bash
rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
```

After a migration, the old agent's plist stays at `~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist.bak`: it can be deleted.

### Contents

| Path | Role |
|---|---|
| `Packages/NacelleProtocol/` | Messages exchanged between the apps and `ptzd`, shared by both |
| `mac/ptzd/` | The service: logic (`PTZCore`), pairing and authentication (`PTZAuth`), USB access (`CUVC`, `UVCCamera`), WebSocket server and local listener (`PTZServer`) |
| `mac/ai/` | The `obsbot-ai` helper (C++): its source, shipped in the app and compiled on the user's Mac; `build.sh` builds it locally with the SDK in `vendor/`, for tests |
| `mac/app/` | The PTZBot for Mac app: `project.yml` (xcodegen), interface (`PTZBot/`), tested logic (`PTZBotKit/`), helper build phase (`build-helpers.sh`), bundle check (`check-bundle.sh`) and update feed (`appcast.xml`, written at publication) |
| `mac/tools/` | Test WebSocket client |
| `ios/` | The iOS app: `project.yml` (xcodegen), sources and tests |
| `outils/` | Publication of a release: `publier.sh`, `publication.py` and their tests, Sparkle's license |
| `NOTES-VERSIONS.md` | Release notes, in English then in French |
| `scripts/install-mac.sh` | Building and installing the app from source on the Mac |
| `docs/` | Specs, plans and feasibility tests |
| `spike/` | **Throwaway** probes from the feasibility tests |

### License

MIT. See [LICENSE](LICENSE). The disk image also carries the license of [Sparkle](https://sparkle-project.org) 2.10.0 (`outils/Sparkle-LICENSE.txt`).

<a id="francais"></a>

## Français

Piloter à distance la nacelle d'une OBSBOT Tiny 2 depuis l'iPhone.

La caméra est branchée en USB sur un Mac qui la diffuse déjà avec [go2rtc](https://github.com/AlexxIT/go2rtc), et vers HomeKit via Homebridge. HomeKit ne sait pas piloter un pan/tilt/zoom : ce projet ajoute ce qui manque.

> Projet personnel, sans lien avec OBSBOT.

### Statut

- **Côté Mac** : l'app **PTZBot pour Mac**, qui contient `ptzd`, s'installe depuis l'image disque des versions publiées (voir « Installer PTZBot pour Mac »), puis se met à jour seule. On peut aussi la compiler depuis les sources avec `scripts/install-mac.sh`. Le SDK OBSBOT s'installe ensuite depuis l'app, qui compile `obsbot-ai` sur le Mac.
- **App iOS** (PTZBot) : s'installe depuis Xcode sur l'iPhone (voir « App iOS » plus bas).

Conception : [spec](docs/superpowers/specs/2026-10-05-nacelle-design.md) · [spec de l'accès local](docs/superpowers/specs/2026-10-06-acces-local-design.md) · [spec de la découverte et du QR code](docs/superpowers/specs/2026-10-06-decouverte-qr-design.md) · [spec de l'app Mac](docs/superpowers/specs/2026-10-06-app-mac-design.md) · [spec de ptzd dans l'app](docs/superpowers/specs/2026-10-07-ptzd-dans-app-design.md) · [spec de la distribution](docs/superpowers/specs/2026-10-08-distribution-design.md) · [plan côté Mac](docs/superpowers/plans/2026-10-05-nacelle-mac.md) · [plan de l'app iOS](docs/superpowers/plans/2026-10-05-nacelle-ios.md) · [plan de l'accès local](docs/superpowers/plans/2026-10-06-acces-local.md) · [plan de la découverte et du QR code](docs/superpowers/plans/2026-10-06-decouverte-qr.md) · [plan de l'app Mac](docs/superpowers/plans/2026-10-06-app-mac.md) · [tests de faisabilité](docs/spike/2026-10-05-faisabilite.md).

### Architecture

```
iPhone : app SwiftUI                         Mac (celui de go2rtc)
┌───────────────────────────┐            ┌──────────────────────────────────┐
│ Joystick, zoom,           │            │ PTZBot.app ▸ ptzd (enfant)       │
│ vie privée, offre vidéo ──┼─ WebSocket▶│   ├─ commandes UVC ──▶ Tiny 2    │
│                           │ authentifié│   ├─ lance obsbot-ai (SDK)       │
│                           │◀─ état ────│   └─ relaie l'offre ──┐          │
│                           │            │                       ▼          │
│ Vidéo WebRTC ◀────────────┼─ images ───│ go2rtc (API en local) ◀── ffmpeg │
└───────────────────────────┘            └──────────────────────────────────┘
   à la maison : Wi-Fi (Bonjour, adresse locale) ; dehors : la même adresse par Tailscale
```

- **`ptzd`** : un service en Swift, rangé dans l'app (`PTZBot.app/Contents/Helpers/ptzd`) et lancé par elle : il ne tourne que pendant que PTZBot est ouvert, et s'arrête de lui-même si l'app disparaît, même tuée de force. PTZBot le relance s'il s'arrête de façon inattendue. C'est le seul à envoyer des commandes de nacelle à la caméra, en UVC. Il écoute sur l'adresse Tailscale du Mac, sur 127.0.0.1, et sur ses interfaces Wi-Fi et Ethernet, où il s'annonce par Bonjour (`_nacelle._tcp`). Chaque iPhone est appairé une fois, sur le réseau local, en scannant le QR code affiché par l'app Mac (ou `ptzd pair`) ; ensuite, il signe un défi à chaque connexion. Sur le réseau local, tout passe en plus dans un canal TLS : pendant l'appairage, sa clé est le secret du QR code ; ensuite, une clé propre à chaque iPhone, remise à l'appairage. Seules les connexions venues de 127.0.0.1 sont dispensées du défi.
- **`obsbot-ai`** : un petit utilitaire qui allume ou coupe le suivi IA de la caméra avec le SDK OBSBOT. `ptzd` lui donne un ordre au premier mouvement du joystick (le suivi contrerait les mouvements), à l'entrée en vie privée et sur ordre des apps. Le chargement du SDK prend environ 4 secondes : `ptzd` lance donc `obsbot-ai serve`, un mode résident où le SDK reste chargé, où `on` et `off` se lisent sur l'entrée standard, un par ligne, et reçoivent pour réponse `obsbot-ai: ready`, puis `obsbot-ai: ok` ou `obsbot-ai: err <code>` pour chaque ordre, si bien qu'un ordre prend effet en quelques millisecondes. `ptzd` le démarre quand un client pilote la caméra (un iPhone qui s'authentifie, ou tout message d'un client), l'arrête après 10 minutes sans activité et au branchement ou débranchement de la caméra, et il se termine seul quand son entrée se ferme, donc aussi si `ptzd` meurt. Le premier ordre après l'ouverture de l'app peut encore prendre quelques secondes. Les modes à un coup `obsbot-ai on` et `obsbot-ai off` restent, pour un usage manuel. PTZBot le compile sur le Mac de l'utilisateur, à partir de sa source livrée dans l'app (`Contents/Resources/obsbot-ai.cpp`) et des en-têtes du SDK, avec les outils de développement d'Apple ; il est rangé à côté du SDK, dans `~/Library/Application Support/ObsbotNacelle/sdk/`, et `ptzd` le lance avec `DYLD_LIBRARY_PATH` vers ce dossier. Ni le SDK ni `obsbot-ai` ne sont dans l'app ou l'image disque : la licence du SDK n'en autorise pas la redistribution.
- **PTZBot pour Mac** : une app dans la barre des menus, qui lance `ptzd` et lui parle par 127.0.0.1 : appairage par QR code, appareils et clients connectés, expulsion, vie privée et suivi IA (voir « App Mac » plus bas). Elle se met à jour avec [Sparkle](https://sparkle-project.org).
- **go2rtc** : `ptzd` lui relaie l'offre WebRTC de l'app ; les images vont ensuite directement de go2rtc à l'iPhone. Voir « go2rtc » plus bas pour le fermer au réseau local.

### Installer PTZBot pour Mac

Prérequis :

- un Mac Apple Silicon sous macOS 15 ou plus récent ;
- Tailscale sur le Mac pour piloter hors de la maison (sans lui, `ptzd` n'écoute que sur 127.0.0.1 et sur le réseau local) ;
- OBSBOT Center fermé : ouvert, il fausse la relecture du tilt ;
- pour le suivi IA seulement : le SDK OBSBOT, à demander sur [obsbot.com/sdk](https://www.obsbot.com/sdk), et les outils de développement d'Apple (PTZBot propose de les installer).

Puis :

1. Télécharger `PTZBot-X.Y.Z.dmg` sur la [page des versions](https://github.com/Djoko-cli/obsbot-nacelle/releases), l'ouvrir et glisser **PTZBot** dans **Applications**.
2. **Première ouverture (Gatekeeper).** PTZBot est signé mais pas notarisé : la première fois, macOS refuse de l'ouvrir. Ouvrir **Réglages Système › Confidentialité et sécurité**, cliquer sur **Ouvrir quand même** à côté du message sur PTZBot, puis confirmer. Ce n'est demandé qu'une fois.
3. Au premier lancement :
   - **Ancienne installation.** Si l'agent launchd `io.github.djoko-cli.obsbot-nacelle.ptzd` d'une version précédente est là, PTZBot propose de le remplacer. **Remplacer** l'arrête, renomme sa plist en `.plist.bak`, met les anciens binaires de `bin/` à la corbeille et reprend le SDK de `lib/`. Les iPhone appairés et les réglages sont conservés. **Plus tard** garde l'ancien `ptzd` (le panneau affiche « Ancienne installation ») ; la question revient au lancement suivant.
   - **`config.json`.** S'il manque, PTZBot le crée avec l'adresse Tailscale du Mac, ou sur 127.0.0.1 seulement sans Tailscale (le panneau le signale).
   - **Autorisations.** macOS demande l'accès au réseau local pour PTZBot (`ptzd` en dépend) : répondre **Autoriser**. À la première connexion de l'iPhone, il peut aussi demander s'il faut autoriser `ptzd` à accepter des connexions entrantes : répondre **Autoriser**. La question peut revenir après une mise à jour, car le binaire change.
4. **SDK OBSBOT.** Dans le panneau, **SDK OBSBOT › Installer le SDK…** : choisir l'archive `.zip` reçue d'OBSBOT ou son dossier décompressé. Un `libdev.dylib` seul est refusé : les en-têtes sont nécessaires pour compiler `obsbot-ai`. PTZBot prend `macos/arm64-release/libdev.dylib` et le dossier `include/` à côté de `macos/` ; les autres copies de la bibliothèque dans l'archive sont listées et ignorées. La fenêtre montre l'architecture, la signature, la provenance et la quarantaine ; **Autoriser ce SDK** copie la bibliothèque et les en-têtes dans `sdk/`, retire la quarantaine de ces copies seulement, compile `obsbot-ai` avec les outils de développement d'Apple, puis vérifie qu'il charge le SDK. Tout se fait d'un seul tenant : si une étape échoue, l'ancien SDK et l'ancien `obsbot-ai` restent, et la sortie du compilateur va dans `obsbot-ai-compilation.log`. Sans SDK, tout marche sauf le suivi IA.
   - **Outils de développement.** Sans eux, la ligne SDK du panneau et la fenêtre **SDK OBSBOT** proposent **Installer les outils de développement…** avant tout choix du SDK. Le bouton lance l'installation d'Apple (`xcode-select --install`), seulement quand on clique : accepter dans la fenêtre d'Apple, puis rouvrir le panneau, ou cliquer sur **Vérifier à nouveau** dans la fenêtre. Un SDK déjà installé dont `obsbot-ai` doit être recompilé affiche « Outils requis », avec le même bouton.
   - **SDK installé par une version précédente.** Un SDK copié sans ses en-têtes (un `libdev.dylib` seul) affiche « À compléter », avec dessous « Réinstallez le SDK depuis son archive ou son dossier : ses en-têtes manquent. » : le réinstaller depuis l'archive.

### Mises à jour

- PTZBot cherche les mises à jour au lancement puis toutes les 24 heures, sur le flux `mac/app/appcast.xml` de ce dépôt. Chaque version est signée par une clé Ed25519, vérifiée avant même la décompression (`SUVerifyUpdateBeforeExtraction`) : Sparkle refuse une version mal signée, quelle que soit sa signature de code.
- Une mise à jour se télécharge en silence et s'installe à la fermeture de l'app, ou tout de suite par **Installer et relancer**. PTZBot arrête d'abord `ptzd`, comme avec **Quitter**.
- **Rechercher les mises à jour…** est dans le panneau ; **Réglages…** porte **Rechercher automatiquement** et **Installer automatiquement** (cochées par défaut), **Ouvrir à la connexion** et la version.
- Après une mise à jour, si la source d'`obsbot-ai` a changé, PTZBot le recompile au lancement (« Recompilation… »), sans rien demander. Si les outils manquent ou si la compilation échoue, l'ancien `obsbot-ai` reste en service et le panneau le signale.
- Les compilations faites depuis les sources (numéro de compilation 1, comme avec `scripts/install-mac.sh`) ne cherchent jamais de mise à jour.

### Compiler depuis les sources

Prérequis : Xcode et [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Le SDK OBSBOT n'est plus nécessaire pour compiler l'app.

```bash
scripts/install-mac.sh
```

Le script compile l'app (`ptzd` dans `Contents/Helpers`, la source d'`obsbot-ai` dans `Contents/Resources`, Sparkle dans `Contents/Frameworks`), ferme l'app en cours, l'installe dans `~/Applications/PTZBot.app` et la lance. Il ne touche ni à launchd ni aux fichiers de `~/Library/Application Support/ObsbotNacelle/`. Une telle compilation garde le numéro 1 : Sparkle n'y démarre jamais. Ne garder qu'une copie de PTZBot : pour revenir aux versions publiées, mettre `~/Applications/PTZBot.app` à la corbeille et installer l'image disque.

`mac/app/check-bundle.sh` vérifie une compilation Release : `ptzd`, la source d'`obsbot-ai` et Sparkle sont là ; le SDK, ses en-têtes et tout binaire `obsbot-ai` sont absents.

Publier une version (mainteneur) : écrire sa section dans `NOTES-VERSIONS.md` (**English**, puis **Français**), régler `MARKETING_VERSION` dans `mac/app/project.yml`, puis lancer `outils/publier.sh X.Y.Z` depuis un `main` propre et à jour. Si elle s'arrête en route, la reprendre depuis `gestes.txt`, dans le dossier des produits, jamais en relançant le script. `outils/publier.sh X.Y.Z --repetition DOSSIER --url-base http://127.0.0.1:PORT …` répète tout sans GitHub.

### Réglages (`config.json`)

| Clé | Rôle | Défaut |
|---|---|---|
| `listenAddress` | Adresse Tailscale du Mac, ou 127.0.0.1 sans Tailscale ; créée par PTZBot au premier lancement | obligatoire |
| `port` | Port WebSocket | 1985 |
| `panMaxSpeed`, `tiltMaxSpeed` | Vitesses UVC maximales (pan 1–80, tilt 1–120) | 40, 60 |
| `panDirection`, `tiltDirection` | Sens de chaque axe, +1 ou -1 | +1, +1 |
| `aiPath` | Chemin de `obsbot-ai`, relatif à `~/Library/Application Support/ObsbotNacelle` (ou absolu) ; quand PTZBot lance `ptzd`, c'est `--ai` qui compte (`sdk/obsbot-ai` ; l'ancienne clé `aiOffPath` est lue si elle manque, sauf si elle nomme `obsbot-ai-off`) | `bin/obsbot-ai` |
| `localNetwork` | Écoute et annonce Bonjour sur le Wi-Fi et l'Ethernet | `true` |
| `go2rtcAPI` | API locale de go2rtc, pour relayer la vidéo | `http://127.0.0.1:1984` |
| `streamName` | Flux go2rtc relayé | `obsbot` |

Après une modification, relancer le service : dans le panneau, éteindre puis rallumer **Service ptzd**.

### Diagnostic

| Besoin | Commande |
|---|---|
| Journal du service | `tail -f ~/Library/Logs/obsbot-nacelle/ptzd.log` |
| Sortie du SDK | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai.log` |
| Compilation d'`obsbot-ai` | `tail ~/Library/Logs/obsbot-nacelle/obsbot-ai-compilation.log` |
| Lire la position de la caméra | `/Applications/PTZBot.app/Contents/Helpers/ptzd uvc get` |
| Appareils appairés | `/Applications/PTZBot.app/Contents/Helpers/ptzd devices` |
| Voir l'annonce Bonjour | `dns-sd -B _nacelle._tcp` (Ctrl-C pour arrêter) |
| Dialoguer avec le service | `swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"adminWatch"}' wait 2` |

Pour une compilation depuis les sources, l'app est dans `~/Applications/PTZBot.app`.

Le Mac ne peut pas se joindre lui-même par son adresse Tailscale : en local, passer par 127.0.0.1.

`ptzd pair`, `ptzd devices` et `ptzd revoke` restent utilisables en ligne de commande avec le binaire de l'app ; `ptzd pair` demande que le service tourne, donc que PTZBot soit ouvert. Le journal et la ligne de commande de `ptzd` restent en français.

### App Mac (PTZBot)

Elle vit dans la barre des menus (icône de la Tiny 2), sans icône dans le Dock, en français sur un Mac en français, en anglais sinon. **Réglages… › Langue** choisit tout de suite Automatique (langue du système), Français ou English ; les fenêtres de mise à jour de Sparkle suivent au prochain lancement. L'iPhone ne pilote la caméra que pendant que PTZBot est ouvert : **Ouvrir à la connexion** en fait l'usage normal. Son panneau montre :

- l'interrupteur **Service ptzd**, retenu d'un lancement à l'autre, et l'état de `ptzd` (« Actif », « Démarrage… », « Arrêté », « Relancé après un arrêt inattendu (n) », « Ne répond pas » avec un lien vers son journal) et de la caméra. Au-delà de 5 arrêts en 2 min, PTZBot cesse de relancer `ptzd` : « ptzd s'arrête sans cesse : ouvrez le journal ». Il ne le relance pas non plus si un autre `ptzd` tourne déjà (verrou `ptzd.lock` ou port de 127.0.0.1 pris : « Le port 1985 est déjà pris… »), si `config.json` est invalide ou si ses arguments sont refusés ;
- la ligne **SDK OBSBOT**, avec un état court à droite (« Prêt », « Absent », « En quarantaine », « Incompatible », « Ne se charge pas », « Outils requis », « À compléter », « Recompilation… », « Compilation impossible », « obsbot-ai introuvable ») et dessous, sur toute la largeur, ce qu'il veut dire et **Installer le SDK…**, **Installer les outils de développement…** ou, quand le SDK est prêt, **Changer…** ; tant que le SDK n'est pas prêt, **Suivi IA** est grisé (« SDK OBSBOT requis »), sauf si un ancien `obsbot-ai` reste en service ;
- les interrupteurs **Vie privée** et **Suivi IA** (le suivi affiche le dernier ordre : l'état réel ne se lit pas, un geste devant la caméra peut le changer) ;
- les clients connectés, avec **Expulser** : la connexion est coupée et l'appareil refusé 10 min (tant que `ptzd` tourne), sans perdre son appairage ;
- **Appairer un iPhone…** : le QR code en image, valable 5 min ; fermer la fenêtre l'annule ;
- **Appareils…** : les appareils appairés, **Débloquer** et **Retirer…** (l'appareil est retiré et ses connexions coupées tout de suite) ;
- **Rechercher les mises à jour…** sur sa propre ligne, puis **Réglages…** (**Rechercher automatiquement**, **Installer automatiquement**, **Ouvrir à la connexion**, la version, par exemple « PTZBot 1.0.0 (412) » ; macOS peut demander un accord dans Réglages › Général › Ouverture) et **Quitter** : arrête `ptzd` (6 s au plus), puis l'app.

Si l'accès au réseau local est refusé à PTZBot, le panneau l'indique, avec un bouton vers les réglages de confidentialité : les iPhone ne trouvent alors le Mac que par Tailscale.

L'app passe par la connexion de confiance de `ptzd` (127.0.0.1) : tout programme du Mac peut en faire autant.

Tests : `(cd mac/app/PTZBotKit && swift test)` ; outils de publication : `python3 -m unittest discover -s outils/tests`.

### App iOS

Prérequis : Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), un identifiant Apple (un compte gratuit suffit), le côté Mac installé, et Tailscale sur l'iPhone pour piloter hors de la maison. L'app iOS n'est encore qu'en français.

Enregistrement : le bouton rec (entre le suivi IA et la vie privée) range dans Photos la vidéo et le son reçus, en MP4 (H.264 et AAC), jusqu'à ce qu'on l'arrête. Le son est enregistré même coupé dans l'app. L'entrée en vie privée, la coupure de la connexion, le passage en arrière-plan ou le manque d'espace arrêtent l'enregistrement et le sauvent ; en vie privée, le bouton reste grisé. Un tap sur la vidéo masque les commandes pour une image nette (pendant un enregistrement, seuls le bouton rec et son chrono restent) ; un autre tap les rend.

1. Indiquer l'équipe de signature dans un réglage local, non versionné. Son identifiant est le champ OU des certificats « Apple Development » du trousseau :

   ```bash
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | grep organizationalUnitName
   ```

   ```bash
   printf 'DEVELOPMENT_TEAM = %s\n' <identifiant> > ios/Config/Local.xcconfig
   ```

2. Générer le projet, puis compiler et installer sur l'iPhone branché ou appairé. `<UDID>` est son identifiant, donné par `xcrun devicectl list devices` :

   ```bash
   (cd ios && xcodegen)
   ```

   ```bash
   xcodebuild build -project ios/Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS,id=<UDID>' -derivedDataPath ios/.build -allowProvisioningUpdates
   ```

   ```bash
   xcrun devicectl device install app --device <UDID> ios/.build/Build/Products/Debug-iphoneos/Nacelle.app
   ```

3. Au premier lancement, iOS demande de faire confiance au développeur : Réglages › Général › VPN et gestion de l'appareil.
4. Au premier lancement, PTZBot cherche le Mac sur le Wi-Fi (« Recherche du Mac à proximité… ») : iOS demande l'accès au réseau local, répondre **Autoriser**.
5. Appairer l'iPhone, sur le même réseau que le Mac : dans PTZBot sur le Mac, **Appairer un iPhone…** affiche un QR code (valable 5 min, un seul usage, 3 essais). En repli, par exemple en SSH, `ptzd pair` l'affiche dans le Terminal :

   ```bash
   /Applications/PTZBot.app/Contents/Helpers/ptzd pair
   ```

   Puis, dans l'app de l'iPhone, toucher **Scanner le QR code** et viser l'écran du Mac (iOS demande l'accès à l'appareil photo). La clé de l'iPhone reste dans sa Secure Enclave ; le Mac garde sa clé publique et le secret du canal chiffré du réseau local, dans `devices.json` (droits 600). L'app retient l'adresse locale du Mac dans Réglages › Adresse du Mac (repli).

   Mise à jour depuis une version qui demandait le nom Tailscale : le champ « Adresse du Mac (repli) » le garde. Pour passer à l'adresse locale (qui sert aussi en 4G par la route de sous-réseau), vider ce champ et toucher Enregistrer avant de scanner : l'app y retiendra l'adresse locale du Mac.
6. Hors de la maison, l'app joint cette même adresse par Tailscale si un appareil du tailnet publie le réseau local (routage de sous-réseau) et si l'iPhone accepte les routes. Sinon, mettre dans le champ le nom Tailscale du Mac (champ `DNSName`, sans le point final, de `tailscale status --self --peers=false --json` sur le Mac) : l'app le joint par l'écoute Tailscale de `ptzd`, sans TLS.

Retirer un iPhone : dans PTZBot sur le Mac, **Appareils…** › **Retirer…** ; ses connexions sont coupées tout de suite, après un message qui l'informe : l'iPhone connecté oublie son appairage et revient à l'écran d'appairage. Un iPhone hors connexion à ce moment l'apprend à sa prochaine connexion par Tailscale ; sur le réseau local, il est simplement refusé et affiche « Mac injoignable » : sur lui, « Oublier cet appairage », puis scanner un nouveau QR code. En ligne de commande, `ptzd devices` donne le début de son identifiant, puis `ptzd revoke <début>` ; ses connexions déjà ouvertes durent alors jusqu'à leur fin. Depuis l'iPhone, « Oublier cet appairage » le retire aussi de la liste du Mac quand il est connecté.

Avec un compte Apple gratuit, l'app expire au bout de 7 jours : refaire l'étape 2.

Tests : `(cd ios && xcodegen && xcodebuild test -project Nacelle.xcodeproj -scheme Nacelle -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' -derivedDataPath .build)`.

### go2rtc

`ptzd` relaie la négociation vidéo à l'API de go2rtc sur 127.0.0.1 : l'API n'a donc plus besoin d'être ouverte au réseau. Configuration conseillée (dans `go2rtc.yaml`, à adapter) :

```yaml
api:
  listen: "127.0.0.1:1984"
rtsp:
  listen: ":8554"
  username: "<identifiant>"
  password: "<mot de passe>"
webrtc:
  listen: ":8555"
ffmpeg:
  bin: /opt/homebrew/bin/ffmpeg   # chemin complet : sous launchd, le PATH ne contient pas /opt/homebrew/bin
streams:
  obsbot:
    - exec:…   # vidéo de la caméra (H.264)
    - exec:…   # micro de la caméra (AAC, pour HomeKit)
    - ffmpeg:obsbot#audio=opus   # le même son en Opus, pour PTZBot (WebRTC)
```

- go2rtc dispense les clients locaux (127.0.0.1) du mot de passe RTSP : les sources `exec:` qui publient sur `{output}` continuent de fonctionner sans changement.
- Un client RTSP du réseau, comme Homebridge, doit alors donner l'identifiant et le mot de passe dans l'adresse du flux : `rtsp://<identifiant>:<mot de passe>@<Mac>:8554/obsbot`.
- Le port WebRTC 8555 reste ouvert : sans offre négociée par `ptzd`, il ne donne aucune image.
- Son dans PTZBot : WebRTC ne transporte pas l'AAC. La source `ffmpeg:obsbot#audio=opus` le convertit en Opus dès que PTZBot est ouvert, même son coupé (le bouton ne fait que couper la lecture, pour que le son revienne tout de suite). Sans la ligne `ffmpeg: bin:`, go2rtc lancé par launchd ne trouve pas `ffmpeg` et la piste audio reste muette, sans message d'erreur.
- `go2rtc.yaml` contient le mot de passe RTSP : le passer en droits 600 (`chmod 600 go2rtc.yaml`).
- Le flux RTSP vers Homebridge, identifiants compris, circule en clair sur le réseau local : un appareil qui intercepte ce trafic peut les lire, ainsi que les images.
- Le QR code d'appairage (fenêtre de PTZBot pour Mac, ou `ptzd pair` et l'URL affichée sous lui) permet d'appairer un appareil pendant 5 minutes : ne l'afficher que le temps du scan.
- Ne jamais exposer 127.0.0.1:1985 au réseau, par exemple avec `tailscale serve` ou `ssh -L` : les connexions venues de 127.0.0.1 sont dispensées d'authentification, tout client distant passé par là piloterait la caméra.

### Désinstaller

Dans PTZBot pour Mac, **Réglages…** › décocher **Ouvrir à la connexion**, puis **Quitter** (`ptzd` s'arrête avec l'app), et mettre `/Applications/PTZBot.app` (ou `~/Applications/PTZBot.app` pour une compilation depuis les sources) à la corbeille.

Les données restent dans `~/Library/Application Support/ObsbotNacelle/` (réglages, iPhone appairés, SDK, ses en-têtes et `obsbot-ai`) et les journaux dans `~/Library/Logs/obsbot-nacelle/`, tant qu'on ne les supprime pas :

```bash
rm -r ~/Library/Application\ Support/ObsbotNacelle ~/Library/Logs/obsbot-nacelle
```

Après une migration, la plist de l'ancien agent reste en `~/Library/LaunchAgents/io.github.djoko-cli.obsbot-nacelle.ptzd.plist.bak` : elle peut être supprimée.

### Contenu

| Chemin | Rôle |
|---|---|
| `Packages/NacelleProtocol/` | Messages échangés entre les apps et `ptzd`, partagés par les deux |
| `mac/ptzd/` | Le service : logique (`PTZCore`), appairage et authentification (`PTZAuth`), accès USB (`CUVC`, `UVCCamera`), serveur WebSocket et écoute locale (`PTZServer`) |
| `mac/ai/` | L'utilitaire `obsbot-ai` (C++) : sa source, livrée dans l'app et compilée sur le Mac de l'utilisateur ; `build.sh` le compile en local avec le SDK de `vendor/`, pour les essais |
| `mac/app/` | L'app PTZBot pour Mac : `project.yml` (xcodegen), interface (`PTZBot/`), logique testée (`PTZBotKit/`), phase des utilitaires (`build-helpers.sh`), vérification du paquet (`check-bundle.sh`) et flux des mises à jour (`appcast.xml`, écrit à la publication) |
| `mac/tools/` | Client WebSocket de test |
| `ios/` | L'app iOS : `project.yml` (xcodegen), sources et tests |
| `outils/` | Publication d'une version : `publier.sh`, `publication.py` et leurs tests, licence de Sparkle |
| `NOTES-VERSIONS.md` | Notes de version, en anglais puis en français |
| `scripts/install-mac.sh` | Compilation et installation de l'app depuis les sources sur le Mac |
| `docs/` | Spec, plans et tests de faisabilité |
| `spike/` | Sondes **jetables** des tests de faisabilité |

### Licence

MIT. Voir [LICENSE](LICENSE). L'image disque porte aussi la licence de [Sparkle](https://sparkle-project.org) 2.10.0 (`outils/Sparkle-LICENSE.txt`).
