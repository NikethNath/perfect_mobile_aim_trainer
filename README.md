# Aim Trainer

A minimal, high-performance aim trainer for Android and iOS. Strict duotone
look: charcoal background (`#12151A`), mint targets and UI (`#3DF0B2`).

## Gameplay

First-person, FPS-style controls:

- **Swipe anywhere** to rotate the camera (yaw/pitch) and move the center
  crosshair onto a target. Multi-touch: aim with one finger while firing
  with another.
- **Tap FIRE** (bottom-right HUD button) to shoot a ray from the crosshair.
- 30-second rounds, 2 targets live in the 3D arena at once. Targets pop in,
  then shrink away over ~3.5 s — shoot them before they vanish.
- Hit: +100 (X hit-marker + haptic). Missed shot or expired target: −25.
- Results screen shows score, hits, misses, accuracy, and average kill time.
- Best score persists between launches.

The 3D is a hand-rolled perspective camera inside the same `CustomPainter`:
targets are spheres in world space, a wireframe floor grid anchors depth,
and shooting is a forward-ray/sphere intersection test — no game engine.

## Performance design

- Game state is plain Dart advanced by a vsync `Ticker`; rendering is a single
  `CustomPaint` — no widget rebuilds or allocations in the per-frame path.
- Input uses `Listener.onPointerDown` (no gesture-arena delay), so taps
  register on pointer-down with the lowest latency Flutter offers.
- HUD text is layout-cached and only re-shaped when the string changes.
- Menu and results screens are fully static: zero CPU/GPU while idle.
- Runs at the display's native refresh rate (90/120 Hz capable).

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

## Tuning

All gameplay constants live at the top of [lib/main.dart](lib/main.dart):
round length, target count, target lifetime, scoring, and the two palette
colors (`kBg` / `kFg`).
