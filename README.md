# Aim Ranked

A minimal, high-performance aim trainer for Android and iOS. Strict duotone
look by default — charcoal background (`#12151A`), mint targets and UI
(`#3DF0B2`) — with every color fully customizable in-app via RGB sliders.

## Gameplay

First-person, FPS-style controls, landscape-locked:

- **Swipe anywhere** to rotate the camera (yaw/pitch) and move the center
  crosshair onto a target. Multi-touch: aim with one finger while firing with
  another.
- **FIRE** (bottom-right HUD button) shoots a ray from the crosshair. The
  first trigger pull starts the round and counts as a real shot — targets are
  visible beforehand so you can line up.
- 60-second rounds. Best score per scenario persists between launches.
- Hit: X marker + haptic, hit sound. Miss: subtle miss sound.

### Scenarios

| Mode | Type | Description |
|------|------|-------------|
| **CUBES** | click | Flick between static cubes on the far wall. Target switching, precision, click timing. |
| **FLOAT 360** | track | Track a single sphere drifting around you in full 360°. Smooth tracking and movement reading. Hold FIRE for full-auto. |
| **REACTIVE** | track | Track a strafing pill that jukes left/right and pushes in/out (KovaaK "Close Fast Strafes" style). Floor grid + vertical wall references make direction changes readable. Hold FIRE for full-auto. |
| **BARDPILL** | click | Pop four small static spheres on a single wall (KovaaK "1w4ts" style). Precise one-shot clicking and fast switching. |
| **REFLEX 360** | track | Track a sphere that snaps to new headings instantly — infinite acceleration, zero easing. Reflex-heavy 360° tracking. Hold FIRE for full-auto. |

### Scoring & ranks

Score is `hits × √accuracy`, normalized per scenario so all four share one
ladder (tracking modes are scaled ×1.43 to match the clicking modes). Each
scenario carries its own rank, shown with a procedurally-drawn badge on the
Profile screen.

The 11-tier ladder (threshold in points):

`BRONZE 20 · SILVER 40 · GOLD 62 · PLATINUM 88 · DIAMOND 118 · EMERALD 152 ·
RUBY 190 · MASTER 235 · GRANDMASTER 290 · ASTRA 350 · CELESTIAL 400`

A Celestial run is roughly 60% accuracy sustained across a full round.

### Customization

- **Crosshair** — RGB color, dot size, line length/width, border thickness and
  color, overall scale, with a live preview.
- **Arena** — background and accent colors via RGB sliders.
- **General** — FOV (40–120°), look sensitivity, FPS counter toggle.
- **HUD editor** — drag the FIRE button anywhere, resize it, set opacity down
  to fully transparent (still tappable).

## Engine

The 3D is a hand-rolled perspective camera inside a single `CustomPainter` —
no game engine. Targets live in world space (cubes via ray–AABB, spheres via
ray–sphere, the REACTIVE pill via ray–capsule); walls use a distance-fog
gradient and a wireframe grid anchors depth.

## Performance design

- Game state is plain Dart advanced by a vsync `Ticker`; rendering is a single
  `CustomPaint` repainting off a `Listenable` — no widget rebuilds or
  allocations in the per-frame path.
- Input uses `Listener.onPointerDown` (no gesture-arena delay), so shots
  register on pointer-down with the lowest latency Flutter offers.
- HUD text is layout-cached and only re-shaped when the string changes.
- Sound effects are decoded once and replayed from a preloaded pool, so even
  full-auto fire never re-decodes audio on the hot path.
- Menu, Profile, Ranks, and results screens are fully static: zero CPU/GPU
  while idle.
- Requests the display's native refresh rate on Android (90/120/144 Hz capable)
  via `flutter_displaymode`; ProMotion is unlocked on iOS via `Info.plist`.

## Integrity

Best scores are HMAC-SHA256-signed in `SharedPreferences` (deters casual
editing on rooted devices). This is tamper-*evident*, not tamper-*proof* —
true leaderboard integrity would require a server.

## Build

```sh
flutter pub get

# Android (any OS)
flutter build apk --release        # APK at build/app/outputs/flutter-apk/
flutter build appbundle --release  # AAB for Play Store

# iOS (requires macOS + Xcode; code is already iOS-ready)
flutter build ipa --release
```

No Mac? Build iOS with a CI service such as Codemagic or a GitHub Actions
`macos` runner.

Run checks with `flutter analyze && flutter test`.

## Tuning

- Gameplay constants live at the top of [lib/main.dart](lib/main.dart): round
  length, target counts/sizes, scoring scales, the rank ladder (`kRanks`), and
  the two default palette colors (`kBg` / `kFg`).
- Per-scenario bot behavior (FLOAT 360, REACTIVE, REFLEX 360) is described by
  `kTuneParams`. The in-app **TUNING** menu (from the main menu) adjusts these
  live and persists them; the `kTuneParams` values are the defaults. Note
  REFLEX 360 has no acceleration slider — it runs at infinite acceleration by
  design.
  