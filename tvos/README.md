# Apple TV

The same native runtime as the Mac app, built for the **Apple TV 4K** (tvOS 17 or later). The game's x86 code is
translated to C on your Mac exactly as Setup does it, compiled for the Apple TV, and put in an app together with your
game folder. You install it on **your own** Apple TV from Xcode's tools. There is no emulator and no JIT.

> You need your own copy of the game (PC, v1.3). The app you build contains your game files: it is for your own Apple
> TV. Never share it, upload it to the App Store or send it to external TestFlight testers.

## Quick start

Everything runs from the Mac; nothing is installed from the Mac's Setup app.

1. Pair the Apple TV with Xcode (see below), awake and on the same network.
2. Create `tvos/local.env` with `TEAM` and `BUNDLE_ID`, and put your PC game folder in the checkout as
   `NFS Most Wanted/` (or set `GAME`).
3. `tvos/tv.sh run` (the first run takes about five minutes to translate the game, then a 3 GB transfer).
4. On the Apple TV, pair a game controller, then open **NFS Most Wanted** from the Home screen. The first launch shows
   a black screen for about 15 seconds.
5. Later: `tvos/tv.sh install` then `tvos/tv.sh launch` after a rebuild, or `tvos/tv.sh upload` for TestFlight.

## What you need

- A Mac with **Xcode** (with the tvOS SDK) and Python 3. The Xcode project is generated with the `xcodeproj` Ruby gem:
  `gem install xcodeproj`.
- An **Apple TV 4K** paired with Xcode: Xcode, Window, Devices and Simulators, **+**, pick the Apple TV and enter the
  code it shows. It must be awake and on the same network as the Mac.
- An Apple developer account signed in to Xcode (Settings, Accounts). Your team ID is shown there.
- Your PC game folder, version 1.3 (the same folder Setup accepts). About 3 GB of it goes into the app.
- A **game controller** paired with the Apple TV (DualSense, DualShock 4, Xbox or another one tvOS supports). The Siri
  Remote can't drive.

## Build and install

From the checkout's root folder, once:

```sh
cat > tvos/local.env <<'EOF'
TEAM=ABCDE12345                          # your team ID
BUNDLE_ID=com.yourname.nfsmw             # a bundle ID of your own
GAME="/path/to/Need for Speed Most Wanted"   # your PC game folder (default: "NFS Most Wanted" in the checkout)
EOF
```

Then:

```sh
tvos/tv.sh run
```

This prepares everything on the Mac (the first time: translating the game, FFmpeg for the Apple TV, about five
minutes), builds the app, installs it on the Apple TV (a 3 GB transfer) and starts it with its log in the terminal.
Ctrl-C stops watching the log; the game keeps running. Afterwards the app is on the Apple TV's Home screen (new apps
go to the end of the list).

**TestFlight** (the app on the Apple TV without the Mac, also on other Apple TVs of yours): create the app in App Store
Connect with your bundle ID, then `tvos/tv.sh upload`. Add yourself as an internal tester and install from the
TestFlight app on the Apple TV. The upload contains your game files: internal testers who own the game only, never
external testing or the App Store. Builds expire after 90 days.

**Icon:** `tvos/tv.sh art` starts the game, captures the title screen from the Apple TV and cuts the logo out
(`tools/title_art.py`, into `out/art`, never committed); the next build uses it. Without it the icon is the Mac app's
generic speedometer.

The steps one at a time: `tvos/tv.sh prepare`, `project`, `build`, `install`, `launch`, and `log` (copies the app's last
log from the Apple TV to `out/NFSMW.log`). `DEVICE=<name or id>` picks another Apple TV.

With a free Apple account the app stops opening after 7 days; build and install it again.

## Playing

- **The first launch** shows a black screen for about 15 seconds while the shaders are compiled; later launches start at
  once.
- **Frame rate** (Apple TV 4K, 3rd generation, A15): races hold 60 fps at 1080p with antialiasing off, the Apple TV
  default (about 14 ms of GPU and 7 ms of game thread per frame). 4x MSAA costs about 6 ms of GPU and gives about 50 fps;
  F10 > Picture > Anti-aliasing still offers it. The TV gets the 1080p picture scaled by the Apple TV.
- **The Siri Remote** moves through menus (swipe for the arrow keys, click for Enter, Menu for Back) but can't drive.
- **F10 settings menu:** on a DualSense or DualShock 4 click the touchpad; on other pads hold View for half a second.
  Rows that have no meaning on the Apple TV (windows, Finder folders, clips, problem reports, HDR output, the output
  format) are not shown.
- **Sound:** PCM 5.1 when the TV or receiver takes six channels (tvOS turns it into Dolby Digital itself when it is set
  to), otherwise stereo. A change of output (TV speakers, receiver, AirPods) reopens the sound in the right format.
- **Rumble** plays on both motors of DualSense, DualShock 4 and Xbox pads (GameController haptics).
- A Bluetooth **keyboard** paired with the Apple TV works as on the Mac.
- The game pauses when you leave it (Home button, screensaver, Control Center) and continues when you come back.
- **Saves** are kept in **iCloud** (the key-value store, `host/tv_cloud.m`) as well as in the app's
  `Library/Caches/NFSMW`, which tvOS may clear when the Apple TV runs out of space. At launch a newer iCloud copy is
  brought in; while you play, changed saves go up within a few seconds and when you leave the app. A profile deleted in
  the game is deleted in iCloud too. Another Apple TV with the same Apple Account gets the saves at its next launch; the
  newest file wins. Settings stay on each Apple TV.
- **Models:** the Apple TV 4K 3rd generation (A15) is tested: 60 fps at the defaults. The 1st generation (A10X) and 2nd
  (A12) run the same build with the same defaults but are not tested; if a race is slow there, lower the graphics in
  F10 > Picture (shadows, resolution).

The Xbox 360 features need the Xbox 360 copy, which this build doesn't take yet: the Apple TV app is the PC game.

## How it is put together

| | |
|---|---|
| `tv.sh` | the commands above; settings from `local.env` |
| `prepare.sh` | the Mac side: Python (`.venv`), the fingerprint check and translation of `speed.exe` (`recomp/build_all.py --generate-only`), the tables (`tools/gen_tables.py --no-x360`), FFmpeg, the icons |
| `build_ffmpeg.sh` | FFmpeg 7.1.1 (the pinned tarball) for `appletvos` or `appletvsimulator` |
| `build.sh` | compiles the translated game, the runtime, the shader translator and the audio/media host into `out/<sdk>/libnfsmw.a` (Xcode runs it) |
| `make_project.rb` | writes `NFSMW.xcodeproj` (generated, not committed) |
| `stage_game.sh` | puts your game folder into the app as `Game/` (APFS clones, so no second copy on disk) |
| `app/` | `Info.plist` and `main.m` |
| `host/tv_app.m` | the UIKit app: the scene's window and its CAMetalLayer, the game thread (boot.c's `main`), folders, preferences, logs, the keyboard, the audio session |
| `host/tv_rumble.m` | rumble through GameController haptics (the Mac's `rumble.m` uses IOKit HID) |
| `host/tv_stubs.m` | the Mac-only features left out: problem reports, clips, Discord |
| `tools/make_icons.py` | the layered Home screen icon and Top Shelf image (the game's title screen, or the Mac app's speedometer) |
| `tools/title_art.py` | cuts the logo and scene out of a title-screen screenshot for the icon |
| `host/tv_cloud.m` | the saves in iCloud |
| `testflight.sh` | Release archive and upload to App Store Connect (`tv.sh upload`) |
| `app/NFSMW.entitlements` | the iCloud key-value capability |

The runtime itself has `TARGET_OS_TV` branches where the Mac uses AppKit or the CoreAudio HAL: `user32.m` (the game
window is the host's view; the host's focus changes and keys are queued for the game thread), `render_present.m` (refresh
rate, SDR output), `overlay.m`, `portmenu.m`, `guide.m`, `natmap.c`, and `media/media.cpp` (RemoteIO in the app's
playback session instead of the default output unit; no Dolby passthrough). `render.m` unpacks DXT textures to BGRA8 on
a GPU without BC texture sampling, which the A15 is (`NFS_BC_DECODE=1` tests that path on a Mac). `render_present.m`
also holds the game thread at Present while the app is in the background, where tvOS refuses GPU work.

The runtime's own test switches work on the Apple TV too, passed as environment variables to `devicectl`, e.g. a race with
the game's AI driving and the performance overlay:

```sh
xcrun devicectl device process launch --device <id> --terminate-existing --console \
    --environment-variables '{"BOOT_LOG":"-","BOOT_RACE":"15.1.1","BOOT_AUTODRIVE":"1","NFS_OVERLAY":"full"}' <bundle id>
```

`xcrun devicectl device capture screenshot --device <id> --destination shot.png` takes a picture of the TV.
