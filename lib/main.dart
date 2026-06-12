import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Palette. Background + UI accent are fixed; the target color is the player's
// choice from settings.
// ---------------------------------------------------------------------------
const Color kBg = Color(0xFF12151A); // charcoal
const Color kFg = Color(0xFF3DF0B2); // mint (UI accent, default target color)

const List<Color> kTargetColors = [
  kFg,
  Color(0xFF2ED9FF), // cyan
  Color(0xFFFFD32A), // yellow
  Color(0xFFFFA502), // orange
  Color(0xFFFF4757), // red
  Color(0xFFFF6BD6), // magenta
  Color(0xFFF2F5F7), // white
];

// Gameplay tuning.
const double kRoundSeconds = 60;
const int kMaxTargets = 3;
const double kGrowTime = 0.1;

// 3D tuning.
const double kCubeHalf = 0.5; // target cube half-extent (world units)
const double kSphereR = 0.27; // FLOAT 360 sphere radius (world units)
// REACTIVE pill target dimensions (world units).
const double kPillR = 0.24; // capsule radius
// Sized so the capsule stands on the floor yet its top reaches the same
// height (1.18 world units) it had when it floated.
const double kPillHalfH = 1.2; // half-length of the capsule's core segment
// Vertical center set so the capsule's bottom cap rests on the floor.
const double kPillYC = kRoomFloor + kPillHalfH + kPillR;
const double kLookSens = 0.0042; // radians per logical pixel of swipe
const double kPitchLimit = 1.1; // radians
const double kNearPlane = 0.2;

// The room: a large cube the player stands inside, eye at the origin,
// centered on the front wall. Targets spawn against the opposite wall.
const double kRoomHalfW = 7; // x in [-7, 7]
const double kRoomFloor = -1.7; // eye height 1.7 above the floor
const double kRoomCeil = 6.3;
const double kRoomFront = -1; // wall right behind the player
const double kRoomBack = 14; // target wall
// FLOAT 360 uses a room centered on the player so the sphere can orbit.
const double kFloatHalfD = 7.5; // room depth +/- around the player

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const AimTrainerApp());
}

class AimTrainerApp extends StatelessWidget {
  const AimTrainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aim Trainer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kFg,
          secondary: kFg,
          surface: kBg,
        ),
      ),
      home: const HomeFlow(),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen flow: menu <-> settings, menu -> playing -> results
// ---------------------------------------------------------------------------
enum _Screen {
  menu,
  profile,
  settings,
  settingsCrosshair,
  settingsColors,
  settingsGeneral,
  hudEdit,
  playing,
  results,
}

const List<String> kScenarios = ['CUBES', 'FLOAT 360', 'REACTIVE'];

const List<Color> kBorderColors = [Color(0xFF000000), ...kTargetColors];

// Arena (trainer) background choices — menu UI keeps its own fixed theme.
const List<Color> kBgColors = [
  kBg, // charcoal
  Color(0xFF0A0E1A), // midnight navy
  Color(0xFF000000), // black
  Color(0xFF14091F), // deep purple
  Color(0xFF14100B), // dark umber
  Color(0xFF0C1208), // olive black
  Color(0xFFF3EFE6), // paper (light)
];

class AppSettings {
  Color targetColor = kFg;
  Color arenaBg = kBg; // trainer background
  Color arenaAccent = kFg; // trainer grid/HUD accent
  Color crosshairColor = kFg;
  double crosshairScale = 1.0; // overall multiplier on the whole crosshair
  double crosshairDot = 2.2; // center dot radius (px); 0 removes it
  double crosshairLength = 10; // length of the 4 lines (px); 0 removes them
  double crosshairWidth = 2.5; // stroke width of the 4 lines (px)
  double crosshairBorder = 0; // outline thickness (px); 0 removes it
  Color crosshairBorderColor = const Color(0xFF000000);
  double sensitivity = 1.0;
  double fov = 50; // degrees across the screen's shortest side

  // HUD layout. Negative coords mean "default position" (bottom-right).
  double fireX = -1; // normalized 0..1 center of the FIRE button
  double fireY = -1;
  double fireScale = 1.0;
  double fireOpacity = 1.0;

  bool showFps = false;

  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    targetColor = Color(prefs.getInt('target_color') ?? kFg.toARGB32());
    arenaBg = Color(prefs.getInt('arena_bg') ?? kBg.toARGB32());
    arenaAccent = Color(prefs.getInt('arena_accent') ?? kFg.toARGB32());
    crosshairColor = Color(prefs.getInt('crosshair_color') ?? kFg.toARGB32());
    crosshairScale = prefs.getDouble('crosshair_scale') ?? 1.0;
    crosshairDot = prefs.getDouble('crosshair_dot') ?? 2.2;
    crosshairLength = prefs.getDouble('crosshair_length') ?? 10;
    crosshairWidth = prefs.getDouble('crosshair_width') ?? 2.5;
    crosshairBorder = prefs.getDouble('crosshair_border') ?? 0;
    crosshairBorderColor =
        Color(prefs.getInt('crosshair_border_color') ?? 0xFF000000);
    sensitivity = prefs.getDouble('sensitivity') ?? 1.0;
    fov = prefs.getDouble('fov') ?? 50;
    fireX = prefs.getDouble('fire_x') ?? -1;
    fireY = prefs.getDouble('fire_y') ?? -1;
    fireScale = prefs.getDouble('fire_scale') ?? 1.0;
    fireOpacity = prefs.getDouble('fire_opacity') ?? 1.0;
    showFps = prefs.getBool('show_fps') ?? false;
  }

  Future<void> save() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('target_color', targetColor.toARGB32());
    await prefs.setInt('arena_bg', arenaBg.toARGB32());
    await prefs.setInt('arena_accent', arenaAccent.toARGB32());
    await prefs.setInt('crosshair_color', crosshairColor.toARGB32());
    await prefs.setDouble('crosshair_scale', crosshairScale);
    await prefs.setDouble('crosshair_dot', crosshairDot);
    await prefs.setDouble('crosshair_length', crosshairLength);
    await prefs.setDouble('crosshair_width', crosshairWidth);
    await prefs.setDouble('crosshair_border', crosshairBorder);
    await prefs.setInt(
        'crosshair_border_color', crosshairBorderColor.toARGB32());
    await prefs.setDouble('sensitivity', sensitivity);
    await prefs.setDouble('fov', fov);
    await prefs.setDouble('fire_x', fireX);
    await prefs.setDouble('fire_y', fireY);
    await prefs.setDouble('fire_scale', fireScale);
    await prefs.setDouble('fire_opacity', fireOpacity);
    await prefs.setBool('show_fps', showFps);
  }
}

/// Shared crosshair renderer used by the game HUD and the settings preview.
/// Border is drawn first as a fatter pass underneath the main color.
void drawCrosshair(Canvas canvas, Offset center, AppSettings s) {
  final double sc = s.crosshairScale;
  final double gap = 6 * sc;
  final double thick = s.crosshairWidth * sc;
  final double len = s.crosshairLength * sc;
  final double dotR = s.crosshairDot * sc;
  final double bw = s.crosshairBorder * sc;

  if (len > 0.1) {
    final Paint stroke = Paint()
      ..color = s.crosshairColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = thick;
    final Paint border = Paint()
      ..color = s.crosshairBorderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = thick + 2 * bw;
    for (final (double dx, double dy) in [
      (1.0, 0.0),
      (-1.0, 0.0),
      (0.0, 1.0),
      (0.0, -1.0)
    ]) {
      final Offset dir = Offset(dx, dy);
      if (bw > 0.05) {
        canvas.drawLine(center + dir * (gap - bw),
            center + dir * (gap + len + bw), border);
      }
      canvas.drawLine(center + dir * gap, center + dir * (gap + len), stroke);
    }
  }
  if (dotR > 0.1) {
    if (bw > 0.05) {
      canvas.drawCircle(center, dotR + bw, Paint()..color = s.crosshairBorderColor);
    }
    canvas.drawCircle(center, dotR, Paint()..color = s.crosshairColor);
  }
}

/// Neutral fire button: plain gray ring and face with a bullet glyph.
/// Deliberately colorless and static — no accent tint, no press lighting.
void drawFireButton(Canvas canvas, Offset c, double r, double op) {
  final Paint face = Paint()
    ..color = const Color(0xFF54595F).withValues(alpha: 0.30 * op);
  final Paint ring = Paint()
    ..color = const Color(0xFF9AA0A6).withValues(alpha: 0.9 * op)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  final Paint glyph = Paint()
    ..color = const Color(0xFFC2C7CD).withValues(alpha: op);
  canvas.drawCircle(c, r, face);
  canvas.drawCircle(c, r, ring);
  // Cartridge pointing up: ogive tip, straight body, slightly wider rim.
  final double h = r * 1.05, w = r * 0.42;
  final Path bullet = Path()
    ..moveTo(c.dx - w / 2, c.dy - h * 0.02)
    ..quadraticBezierTo(c.dx - w / 2, c.dy - h * 0.36, c.dx, c.dy - h * 0.5)
    ..quadraticBezierTo(
        c.dx + w / 2, c.dy - h * 0.36, c.dx + w / 2, c.dy - h * 0.02)
    ..lineTo(c.dx + w / 2, c.dy + h * 0.26)
    ..lineTo(c.dx - w / 2, c.dy + h * 0.26)
    ..close();
  canvas.drawPath(bullet, glyph);
  canvas.drawRect(
    Rect.fromLTRB(
        c.dx - w * 0.66, c.dy + h * 0.32, c.dx + w * 0.66, c.dy + h * 0.44),
    glyph,
  );
}

class RoundStats {
  int hits = 0;
  int misses = 0;
  double sumKillMs = 0;

  double get accuracy => hits + misses == 0 ? 0 : hits / (hits + misses);
  double get avgKillMs => hits == 0 ? 0 : sumKillMs / hits;

  /// Score formula: hits weighted by the square root of accuracy.
  int get score => (hits * math.sqrt(accuracy)).round();
}

// ---------------------------------------------------------------------------
// Rank ladder. Thresholds are on the hits*sqrt(accuracy) score.
// ---------------------------------------------------------------------------
class Rank {
  const Rank(this.name, this.threshold, this.color);

  final String name;
  final int threshold;
  final Color color;
}

const List<Rank> kRanks = [
  Rank('BRONZE', 20, Color(0xFFCD7F32)),
  Rank('SILVER', 40, Color(0xFFC8CDD4)),
  Rank('GOLD', 62, Color(0xFFFFD24A)),
  Rank('PLATINUM', 88, Color(0xFF5CE1E6)),
  Rank('DIAMOND', 118, Color(0xFFB9E8FF)),
  Rank('EMERALD', 152, Color(0xFF2ECC71)),
  Rank('RUBY', 190, Color(0xFFE0356F)),
  Rank('MASTER', 235, Color(0xFFB57BFF)),
  Rank('GRANDMASTER', 290, Color(0xFFFF5C5C)),
  Rank('ASTRA', 350, Color(0xFF8FD0FF)),
  Rank('CELESTIAL', 400, Color(0xFFEFFBFF)),
];

/// Highest rank whose threshold the score meets, or null when unranked.
Rank? rankFor(int score) {
  Rank? earned;
  for (final Rank r in kRanks) {
    if (score >= r.threshold) earned = r;
  }
  return earned;
}

/// Next rank above the score, or null at the top.
Rank? nextRankFor(int score) {
  for (final Rank r in kRanks) {
    if (score < r.threshold) return r;
  }
  return null;
}

/// Procedural rank insignia — one geometric badge per tier, drawn in the
/// rank's color. No image assets; crisp at any size.
class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.rank, this.size = 56});

  final Rank? rank; // null renders the unranked placeholder
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _RankBadgePainter(rank),
    );
  }
}

class _RankBadgePainter extends CustomPainter {
  _RankBadgePainter(this.rank);

  final Rank? rank;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;

    if (rank == null) {
      // Unranked: dashed circle.
      final Paint p = Paint()
        ..color = kFg.withValues(alpha: .3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, r * 0.07);
      final Rect rect = Rect.fromCircle(center: c, radius: r * 0.7);
      for (int i = 0; i < 12; i++) {
        canvas.drawArc(rect, i * math.pi / 6, math.pi / 9, false, p);
      }
      return;
    }

    final Color col = rank!.color;
    final Paint fill = Paint()..color = col;
    final Paint stroke = Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, r * 0.13)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (kRanks.indexOf(rank!)) {
      case 0: // Bronze: one chevron
        _chevrons(canvas, c, r, 1, stroke);
      case 1: // Silver: two chevrons
        _chevrons(canvas, c, r, 2, stroke);
      case 2: // Gold: three chevrons
        _chevrons(canvas, c, r, 3, stroke);
      case 3: // Platinum: winged diamond
        _diamond(canvas, c, r * 0.82, fill, stroke);
        for (final double s in [-1, 1]) {
          final Path wing = Path()
            ..moveTo(c.dx + s * r * 0.55, c.dy + r * 0.30)
            ..lineTo(c.dx + s * r * 0.92, c.dy)
            ..lineTo(c.dx + s * r * 0.55, c.dy - r * 0.30);
          canvas.drawPath(wing, stroke);
        }
      case 4: // Diamond: classic rhombus
        _diamond(canvas, c, r, fill, stroke);
      case 5: // Emerald: emerald-cut hexagon
        _hexagon(canvas, c, r, fill, stroke);
      case 6: // Ruby: faceted gemstone
        _gem(canvas, c, r, fill, stroke);
      case 7: // Master: star
        canvas.drawPath(_star(c, r * 0.72), fill);
      case 8: // Grandmaster: star in a ring
        canvas.drawPath(_star(c, r * 0.52), fill);
        canvas.drawCircle(c, r * 0.78, stroke);
      case 9: // Astra: four-point sparkle with twin glints
        canvas.drawPath(_sparkle(c, r * 0.8), fill);
        final Paint glint = Paint()..color = col;
        canvas.drawCircle(
            c + Offset(r * 0.55, -r * 0.55), r * 0.10, glint);
        canvas.drawCircle(
            c + Offset(-r * 0.55, r * 0.55), r * 0.07, glint);
      case 10: // Celestial: radiant star in a ring
        canvas.drawPath(_star(c, r * 0.42), fill);
        canvas.drawCircle(c, r * 0.62, stroke);
        final Paint ray = Paint()
          ..color = col
          ..strokeWidth = math.max(1.5, r * 0.08)
          ..strokeCap = StrokeCap.round;
        for (int i = 0; i < 8; i++) {
          final double a = i * math.pi / 4 + math.pi / 8;
          final Offset dir = Offset(math.cos(a), math.sin(a));
          canvas.drawLine(c + dir * r * 0.74, c + dir * r * 0.95, ray);
        }
    }
  }

  /// Four-pointed twinkle: outer points on the axes, pinched waist between.
  static Path _sparkle(Offset c, double r) {
    final Path path = Path();
    for (int i = 0; i < 8; i++) {
      final double radius = i.isEven ? r : r * 0.26;
      final double a = -math.pi / 2 + i * math.pi / 4;
      final Offset p = c + Offset(math.cos(a), math.sin(a)) * radius;
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  static void _hexagon(
      Canvas canvas, Offset c, double r, Paint fill, Paint stroke) {
    Path hex(double k) {
      final Path p = Path();
      for (int i = 0; i < 6; i++) {
        final double a = -math.pi / 2 + i * math.pi / 3;
        final Offset v = c + Offset(math.cos(a), math.sin(a)) * r * 0.68 * k;
        if (i == 0) {
          p.moveTo(v.dx, v.dy);
        } else {
          p.lineTo(v.dx, v.dy);
        }
      }
      return p..close();
    }

    canvas.drawPath(hex(1), stroke);
    canvas.drawPath(hex(0.5), fill);
  }

  static void _gem(
      Canvas canvas, Offset c, double r, Paint fill, Paint stroke) {
    // Classic gemstone: trapezoid crown over a triangular pavilion.
    final Path gem = Path()
      ..moveTo(c.dx - r * 0.38, c.dy - r * 0.52)
      ..lineTo(c.dx + r * 0.38, c.dy - r * 0.52)
      ..lineTo(c.dx + r * 0.68, c.dy - r * 0.10)
      ..lineTo(c.dx, c.dy + r * 0.62)
      ..lineTo(c.dx - r * 0.68, c.dy - r * 0.10)
      ..close();
    canvas.drawPath(gem, fill);
    // Dark facet line separating crown from pavilion.
    final Paint facet = Paint()
      ..color = const Color(0xAA000000)
      ..strokeWidth = math.max(1.2, r * 0.07);
    canvas.drawLine(Offset(c.dx - r * 0.68, c.dy - r * 0.10),
        Offset(c.dx + r * 0.68, c.dy - r * 0.10), facet);
  }

  static void _chevrons(
      Canvas canvas, Offset c, double r, int n, Paint stroke) {
    final double step = r * 0.38;
    final double top = c.dy - (n - 1) * step / 2 - r * 0.12;
    for (int i = 0; i < n; i++) {
      final double y = top + i * step;
      final Path chevron = Path()
        ..moveTo(c.dx - r * 0.55, y + r * 0.22)
        ..lineTo(c.dx, y - r * 0.18)
        ..lineTo(c.dx + r * 0.55, y + r * 0.22);
      canvas.drawPath(chevron, stroke);
    }
  }

  static void _diamond(
      Canvas canvas, Offset c, double r, Paint fill, Paint stroke) {
    Path rhombus(double k) => Path()
      ..moveTo(c.dx, c.dy - r * 0.72 * k)
      ..lineTo(c.dx + r * 0.52 * k, c.dy)
      ..lineTo(c.dx, c.dy + r * 0.72 * k)
      ..lineTo(c.dx - r * 0.52 * k, c.dy)
      ..close();
    canvas.drawPath(rhombus(1), stroke);
    canvas.drawPath(rhombus(0.45), fill);
  }

  static Path _star(Offset c, double r) {
    final Path path = Path();
    for (int i = 0; i < 10; i++) {
      final double radius = i.isEven ? r : r * 0.42;
      final double a = -math.pi / 2 + i * math.pi / 5;
      final Offset p = c + Offset(math.cos(a), math.sin(a)) * radius;
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(_RankBadgePainter oldDelegate) =>
      oldDelegate.rank != rank;
}

class HomeFlow extends StatefulWidget {
  const HomeFlow({super.key});

  @override
  State<HomeFlow> createState() => _HomeFlowState();
}

class _HomeFlowState extends State<HomeFlow> {
  final AppSettings _settings = AppSettings();
  _Screen _screen = _Screen.menu;
  RoundStats? _last;
  final Map<int, int> _bests = {}; // best score per scenario index
  int _scenario = 0;
  int _round = 0; // bumped to force a fresh GameScreen on restart

  int get _best => _bests[_scenario] ?? 0;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        for (int i = 0; i < kScenarios.length; i++) {
          _bests[i] = prefs.getInt('best_${kScenarios[i]}') ?? 0;
        }
      });
    });
    _settings.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _saveSettings() {
    setState(() {});
    _settings.save();
  }

  void _onRoundFinished(RoundStats stats) {
    if (stats.score > _best) {
      _bests[_scenario] = stats.score;
      SharedPreferences.getInstance().then((prefs) =>
          prefs.setInt('best_${kScenarios[_scenario]}', stats.score));
    }
    setState(() {
      _last = stats;
      _screen = _Screen.results;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_screen) {
        _Screen.menu => _MenuScreen(
            best: _best,
            scenario: _scenario,
            onScenario: (i) => setState(() => _scenario = i),
            onStart: () => setState(() => _screen = _Screen.playing),
            onProfile: () => setState(() => _screen = _Screen.profile),
            onSettings: () => setState(() => _screen = _Screen.settings),
          ),
        _Screen.profile => _ProfileScreen(
            bests: _bests,
            onBack: () => setState(() => _screen = _Screen.menu),
          ),
        _Screen.settings => _SettingsScreen(
            onCrosshair: () =>
                setState(() => _screen = _Screen.settingsCrosshair),
            onColors: () => setState(() => _screen = _Screen.settingsColors),
            onGeneral: () => setState(() => _screen = _Screen.settingsGeneral),
            onHud: () => setState(() => _screen = _Screen.hudEdit),
            onBack: () => setState(() => _screen = _Screen.menu),
          ),
        _Screen.settingsCrosshair => _CrosshairSettingsScreen(
            settings: _settings,
            onChanged: _saveSettings,
            onBack: () => setState(() => _screen = _Screen.settings),
          ),
        _Screen.settingsColors => _ColorsSettingsScreen(
            settings: _settings,
            onChanged: _saveSettings,
            onBack: () => setState(() => _screen = _Screen.settings),
          ),
        _Screen.settingsGeneral => _GeneralSettingsScreen(
            settings: _settings,
            onChanged: _saveSettings,
            onBack: () => setState(() => _screen = _Screen.settings),
          ),
        _Screen.hudEdit => _HudEditScreen(
            settings: _settings,
            onChanged: _saveSettings,
            onBack: () => setState(() => _screen = _Screen.settings),
          ),
        _Screen.playing => GameScreen(
            key: ValueKey<int>(_round),
            settings: _settings,
            scenario: _scenario,
            onFinished: _onRoundFinished,
            onQuit: () => setState(() => _screen = _Screen.menu),
            onRestart: () => setState(() => _round++),
          ),
        _Screen.results => _ResultsScreen(
            stats: _last!,
            best: _best,
            onReplay: () => setState(() => _screen = _Screen.playing),
            onMenu: () => setState(() => _screen = _Screen.menu),
          ),
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Game engine — 3D room, first-person camera, plain Dart advanced by a
// Ticker. No widget rebuilds in the per-frame path.
// ---------------------------------------------------------------------------
class TargetCube {
  TargetCube(this.x, this.y, this.z, this.born);

  final double x; // world-space center
  final double y;
  final double z;
  final double born; // game clock seconds at spawn
}

class GameEngine extends ChangeNotifier {
  GameEngine({required this.onFinished});

  final void Function(RoundStats) onFinished;
  final math.Random _rng = math.Random();
  final List<TargetCube> targets = <TargetCube>[];

  RoundStats stats = RoundStats();
  double clock = 0; // seconds since the round began
  bool started = false; // round begins on the first FIRE press
  bool running = true;
  bool paused = false;
  double _autoFireT = 0; // cooldown for held-trigger fire in tracking modes
  Size arena = Size.zero;
  int scenario = 0; // index into kScenarios

  // FLOAT 360 state: one sphere wandering around the player in spherical
  // coordinates. Velocities ease toward freshly randomized targets, so the
  // motion accelerates and decelerates gradually — built for tracking.
  double sAz = 0, sEl = 0.12, sDist = 5.5; // position
  double vAz = 0, vEl = 0, vDist = 0; // current velocity
  double tAz = 0.6, tEl = 0, tDist = 0; // velocity the easing chases
  double _retargetT = 0;
  double _lastHitClock = 0;

  double get sphereX => sDist * math.cos(sEl) * math.sin(sAz);
  double get sphereY => sDist * math.sin(sEl);
  double get sphereZ => sDist * math.cos(sEl) * math.cos(sAz);

  // REACTIVE state: a pill that orbit-strafes around the centered player and
  // pushes in/out. Erratic leg lengths, snappy accel/decel.
  double rAz = 0, rDist = 3.5; // position (azimuth, distance)
  double rvS = 0, rvD = 0; // strafe (linear u/s) and depth velocities
  double rtS = 0, rtD = 0; // velocities the easing chases
  double _rRetargetT = 0;

  double get rpX => rDist * math.sin(rAz);
  double get rpZ => rDist * math.cos(rAz);

  // HUD layout, copied from AppSettings at round start.
  double fireXNorm = -1;
  double fireYNorm = -1;
  double fireScale = 1.0;
  double fireOpacity = 1.0;

  // First-person camera at the origin, starting square at the target wall.
  double yaw = 0;
  double pitch = 0;
  double sensitivity = 1.0;
  double fov = 50; // degrees

  // Transient feedback timer (seconds remaining).
  double hitT = 0; // hit marker after a kill
  bool firePressed = false;

  double fps = 0; // smoothed, fed by the ticker from raw frame deltas

  double get timeLeft =>
      (kRoundSeconds - clock).clamp(0, kRoundSeconds).toDouble();

  double get focal =>
      arena.shortestSide * 0.5 / math.tan(fov * math.pi / 360);

  // Fire button geometry (player-adjustable via Customise HUD).
  double get fireR =>
      (arena.shortestSide * 0.115 * fireScale).clamp(28.0, 200.0);
  Offset get fireCenter {
    if (fireXNorm < 0 || fireYNorm < 0) {
      return Offset(arena.width - fireR - 26, arena.height - fireR - 30);
    }
    return Offset(
      (fireXNorm * arena.width).clamp(fireR, arena.width - fireR),
      (fireYNorm * arena.height).clamp(fireR, arena.height - fireR),
    );
  }

  bool inFireButton(Offset p) => (p - fireCenter).distance <= fireR * 1.25;

  // Pause button (top-right corner).
  Rect get pauseRect => Rect.fromLTWH(arena.width - 62, 14, 48, 48);
  bool inPauseButton(Offset p) => pauseRect.inflate(8).contains(p);

  void look(Offset delta) {
    if (!running || paused) return;
    final double s = kLookSens * sensitivity;
    yaw += delta.dx * s;
    pitch = (pitch - delta.dy * s).clamp(-kPitchLimit, kPitchLimit);
    notifyListeners();
  }

  /// World point -> camera space (x right, y up, z forward).
  (double, double, double) toCamera(double px, double py, double pz) {
    final double cy = math.cos(yaw), sy = math.sin(yaw);
    final double cp = math.cos(pitch), sp = math.sin(pitch);
    final double x1 = px * cy - pz * sy;
    final double z1 = px * sy + pz * cy;
    final double y2 = py * cp - z1 * sp;
    final double z2 = py * sp + z1 * cp;
    return (x1, y2, z2);
  }

  void update(double dt) {
    if (!running || paused) return;
    if (hitT > 0) hitT -= dt;
    if (!started) {
      // Pre-round: targets are already placed and visible, just frozen.
      if (scenario == 0 && arena != Size.zero) {
        while (targets.length < kMaxTargets) {
          targets.add(_spawn());
        }
      }
      notifyListeners();
      return;
    }
    clock += dt;
    if (scenario == 1) {
      _updateFloat(dt);
    } else if (scenario == 2) {
      _updateReactive(dt);
    } else if (arena != Size.zero) {
      while (targets.length < kMaxTargets) {
        targets.add(_spawn());
      }
    }
    // Tracking modes: a held trigger fires full-auto.
    if (scenario != 0 && firePressed) {
      _autoFireT -= dt;
      if (_autoFireT <= 0) {
        shoot();
      }
    }
    if (clock >= kRoundSeconds) {
      running = false;
      onFinished(stats);
    }
    notifyListeners();
  }

  void _updateFloat(double dt) {
    _retargetT -= dt;
    if (_retargetT <= 0) {
      _retargetT = 0.3 + _rng.nextDouble() * 0.6;
      tAz = (_rng.nextDouble() * 2 - 1) * 1.9; // rad/s around the player
      tEl = (_rng.nextDouble() * 2 - 1) * 0.55;
      tDist = (_rng.nextDouble() * 2 - 1) * 1.6;
    }
    // Ease current velocity toward the target velocity. Punchy (~0.4s time
    // constant): the sphere lunges into new headings and brakes hard.
    final double k = math.min(1, dt * 2.5);
    vAz += (tAz - vAz) * k;
    vEl += (tEl - vEl) * k;
    vDist += (tDist - vDist) * k;
    sAz += vAz * dt;
    sEl += vEl * dt;
    sDist += vDist * dt;
    // Soft bounds: clamp and send the wander target back inward.
    if (sEl > 0.55) {
      sEl = 0.55;
      tEl = -tEl.abs();
    } else if (sEl < -0.15) {
      sEl = -0.15;
      tEl = tEl.abs();
    }
    // Keep the sphere inside the centered room (half-width 7, radius 0.55).
    if (sDist > 6.2) {
      sDist = 6.2;
      tDist = -tDist.abs();
    } else if (sDist < 3.5) {
      sDist = 3.5;
      tDist = tDist.abs();
    }
  }

  void _updateReactive(double dt) {
    _rRetargetT -= dt;
    if (_rRetargetT <= 0) {
      // Erratic legs: random duration means random strafe distances —
      // short jukes through committed runs. Strafe and depth are picked
      // with identical (uniform, symmetric) probability.
      _rRetargetT = 0.11 + _rng.nextDouble() * 0.52;
      const double topStrafe = 5.6; // linear world units/s
      const double topDepth = 3.6;
      // Strafe legs always commit to full speed — only the direction is
      // random, so the pill never dawdles at low velocity.
      rtS = (_rng.nextBool() ? 1 : -1) * topStrafe;
      rtD = (_rng.nextBool() ? 1 : -1) *
          (0.4 + _rng.nextDouble() * 0.6) *
          topDepth;
    }
    // Snappy easing: hits top speed (and stops) fast.
    final double k = math.min(1, dt * 7.2);
    rvS += (rtS - rvS) * k;
    rvD += (rtD - rvD) * k;
    rAz += rvS / rDist * dt; // constant linear strafe speed at any distance
    rDist += rvD * dt;
    // Close-range band, after KovaaK's "Close Fast Strafes Invincible".
    if (rDist > 4.5) {
      rDist = 4.5;
      rtD = -rtD.abs();
    } else if (rDist < 2.5) {
      rDist = 2.5;
      rtD = rtD.abs();
    }
  }

  /// Ray-capsule test against the pill (vertical capsule at rpX/rpZ).
  bool _hitPill(double fx, double fy, double fz) {
    final double dd = fx * fx + fz * fz;
    if (dd < 1e-9) return false; // looking straight up/down
    // Closest approach of the ray to the pill's vertical axis, in XZ.
    final double t = (rpX * fx + rpZ * fz) / dd;
    if (t < 0) return false;
    final double ex = rpX - fx * t, ez = rpZ - fz * t;
    if (ex * ex + ez * ez > kPillR * kPillR) return false;
    final double yAt = fy * t;
    final double yLo = kPillYC - kPillHalfH, yHi = kPillYC + kPillHalfH;
    if (yAt >= yLo && yAt <= yHi) return true;
    // Near an end: test the cap sphere.
    final double cy = yAt < yLo ? yLo : yHi;
    final double dot = rpX * fx + cy * fy + rpZ * fz;
    final double d2 = rpX * rpX + cy * cy + rpZ * rpZ - dot * dot;
    return dot > 0 && d2 <= kPillR * kPillR;
  }

  /// Quick grow-in on spawn; targets then live until shot. Pre-round
  /// targets stand at full size so the player sees them before starting.
  double halfOf(TargetCube t) {
    final double age = started ? clock - t.born : kGrowTime;
    final double grow =
        Curves.easeOutBack.transform((age / kGrowTime).clamp(0.0, 1.0));
    return kCubeHalf * grow;
  }

  /// Cubes spawn against the wall opposite the player.
  TargetCube _spawn() {
    const double z = kRoomBack - kCubeHalf - 0.3;
    double x = 0, y = 1.5;
    for (int i = 0; i < 24; i++) {
      x = (_rng.nextDouble() * 2 - 1) * (kRoomHalfW - 2);
      y = kRoomFloor + 1.0 + _rng.nextDouble() * (kRoomCeil - kRoomFloor - 2.5);
      final bool clear = targets.every((t) {
        final double dx = x - t.x, dy = y - t.y;
        return dx * dx + dy * dy > 2.2 * 2.2;
      });
      if (clear) break;
    }
    return TargetCube(x, y, z, clock);
  }

  /// Ray-AABB slab test from the crosshair; nearest hit wins.
  void shoot() {
    if (!running || paused) return;
    // The first trigger pull starts the clock AND counts as a real shot.
    started = true;
    _autoFireT = 0.1; // full-auto cadence (10 rounds/s) while held
    HapticFeedback.selectionClick();
    if (scenario == 2) {
      final double cp2 = math.cos(pitch);
      final bool hit =
          _hitPill(cp2 * math.sin(yaw), math.sin(pitch), cp2 * math.cos(yaw));
      if (hit) {
        stats.hits++;
        stats.sumKillMs += (clock - _lastHitClock) * 1000;
        _lastHitClock = clock;
        hitT = 0.18;
        HapticFeedback.lightImpact();
      } else {
        stats.misses++;
      }
      notifyListeners();
      return;
    }
    if (scenario == 1) {
      // Ray-sphere: does the forward ray pass within the sphere's radius?
      final (double cx, double cyy, double cz) =
          toCamera(sphereX, sphereY, sphereZ);
      if (cz > kNearPlane && math.sqrt(cx * cx + cyy * cyy) <= kSphereR) {
        stats.hits++;
        stats.sumKillMs += (clock - _lastHitClock) * 1000;
        _lastHitClock = clock;
        hitT = 0.18;
        HapticFeedback.lightImpact();
      } else {
        stats.misses++;
      }
      notifyListeners();
      return;
    }
    final double cp = math.cos(pitch);
    final double fx = cp * math.sin(yaw);
    final double fy = math.sin(pitch);
    final double fz = cp * math.cos(yaw);
    int best = -1;
    double bestT = double.infinity;
    for (int i = 0; i < targets.length; i++) {
      final TargetCube t = targets[i];
      final double h = halfOf(t);
      double tmin = -double.infinity, tmax = double.infinity;
      bool miss = false;
      for (final (double o, double d) in [(t.x, fx), (t.y, fy), (t.z, fz)]) {
        if (d.abs() < 1e-9) {
          if (o - h > 0 || o + h < 0) {
            miss = true;
            break;
          }
          continue;
        }
        double t1 = (o - h) / d, t2 = (o + h) / d;
        if (t1 > t2) (t1, t2) = (t2, t1);
        tmin = math.max(tmin, t1);
        tmax = math.min(tmax, t2);
      }
      if (!miss && tmax >= math.max(tmin, 0) && tmin < bestT) {
        best = i;
        bestT = tmin;
      }
    }
    if (best >= 0) {
      final TargetCube t = targets.removeAt(best);
      stats.hits++;
      stats.sumKillMs += (clock - t.born) * 1000;
      hitT = 0.18;
      HapticFeedback.lightImpact();
      targets.add(_spawn());
    } else {
      stats.misses++;
    }
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Game screen — raw pointer routing: one finger swipes to aim while another
// presses FIRE. Listener avoids the gesture-arena delay entirely.
// ---------------------------------------------------------------------------
class GameScreen extends StatefulWidget {
  const GameScreen({
    super.key,
    required this.settings,
    required this.scenario,
    required this.onFinished,
    required this.onQuit,
    required this.onRestart,
  });

  final AppSettings settings;
  final int scenario;
  final void Function(RoundStats) onFinished;
  final VoidCallback onQuit;
  final VoidCallback onRestart;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  late final GameEngine _game;
  late final Ticker _ticker;
  Duration _prev = Duration.zero;

  int? _lookPointer;
  int? _firePointer;
  Offset _lastLook = Offset.zero;

  @override
  void initState() {
    super.initState();
    _game = GameEngine(onFinished: widget.onFinished)
      ..scenario = widget.scenario
      ..sensitivity = widget.settings.sensitivity
      ..fov = widget.settings.fov
      ..fireXNorm = widget.settings.fireX
      ..fireYNorm = widget.settings.fireY
      ..fireScale = widget.settings.fireScale
      ..fireOpacity = widget.settings.fireOpacity;
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final double dt =
        (elapsed - _prev).inMicroseconds / Duration.microsecondsPerSecond;
    _prev = elapsed;
    if (dt > 0 && dt < 0.5) {
      _game.fps += (1 / dt - _game.fps) * 0.1;
    }
    // Clamp dt so a dropped frame or app pause can't teleport the clock.
    _game.update(dt.clamp(0.0, 1 / 15));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _game.dispose();
    super.dispose();
  }

  void _setPaused(bool v) {
    setState(() {
      _game.paused = v;
      if (v) {
        _ticker.stop();
      } else {
        _prev = Duration.zero;
        _ticker.start();
      }
    });
  }

  void _down(PointerDownEvent e) {
    if (_game.inPauseButton(e.localPosition)) {
      _setPaused(true);
      return;
    }
    if (_game.inFireButton(e.localPosition) && _firePointer == null) {
      _firePointer = e.pointer;
      _game.firePressed = true;
      _game.shoot();
    } else if (_lookPointer == null) {
      _lookPointer = e.pointer;
      _lastLook = e.localPosition;
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer == _lookPointer) {
      _game.look(e.localPosition - _lastLook);
      _lastLook = e.localPosition;
    }
  }

  void _up(int pointer) {
    if (pointer == _lookPointer) _lookPointer = null;
    if (pointer == _firePointer) {
      _firePointer = null;
      _game.firePressed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: (e) => _up(e.pointer),
          onPointerCancel: (e) => _up(e.pointer),
          child: CustomPaint(
            painter: _GamePainter(_game, widget.settings),
            size: Size.infinite,
            willChange: true,
          ),
        ),
        if (_game.paused)
          Container(
            color: kBg.withValues(alpha: 0.88),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('PAUSED', style: _fgStyle(24, spacing: 8)),
                  const SizedBox(height: 40),
                  OutlinedButton(
                    style: _buttonStyle(),
                    onPressed: () => _setPaused(false),
                    child: const Text('RESUME'),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton(
                    style: _buttonStyle(),
                    onPressed: widget.onRestart,
                    child: const Text('RESTART'),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton(
                    style: _buttonStyle(),
                    onPressed: widget.onQuit,
                    child: const Text('MENU'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// TextPainter that only re-lays-out when its string changes.
class _CachedText {
  _CachedText(this.fontSize, {this.weight = FontWeight.w600, this.color = kFg});

  final double fontSize;
  final FontWeight weight;
  final Color color;
  String? _last;
  TextPainter? _tp;

  TextPainter of(String s) {
    if (s != _last) {
      _tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: weight,
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 1.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      _last = s;
    }
    return _tp!;
  }
}

class _GamePainter extends CustomPainter {
  _GamePainter(this.game, this.settings) : super(repaint: game) {
    _cubeFill.color = settings.targetColor;
    _fxStroke
      ..color = settings.crosshairColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = settings.crosshairWidth;
    _bgPaint.color = settings.arenaBg;
    _accentFill.color = settings.arenaAccent;
    _edgePaint
      ..color = settings.arenaAccent.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    _cubeEdge.color = settings.arenaBg;
    // Distance-fog endpoints and per-face cube shades, derived from the
    // player's arena/target colors.
    _fogNear = Color.lerp(settings.arenaBg, settings.arenaAccent, 0.22)!;
    _fogFar = Color.lerp(settings.arenaBg, const Color(0xFF000000), 0.65)!;
    _shadeTop =
        Color.lerp(const Color(0xFF000000), settings.targetColor, 0.85)!;
    _shadeBottom =
        Color.lerp(const Color(0xFF000000), settings.targetColor, 0.55)!;
    _shadeSide =
        Color.lerp(const Color(0xFF000000), settings.targetColor, 0.68)!;
  }

  late final Color _fogNear;
  late final Color _fogFar;
  late final Color _shadeTop;
  late final Color _shadeBottom;
  late final Color _shadeSide;

  final GameEngine game;
  final AppSettings settings;
  final Paint _fxStroke = Paint();
  final Paint _bgPaint = Paint();
  final Paint _accentFill = Paint();
  final Paint _edgePaint = Paint();
  final Paint _cubeFill = Paint();
  final Paint _cubeEdge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeJoin = StrokeJoin.round;

  late final _CachedText _scoreText =
      _CachedText(20, color: settings.arenaAccent);
  late final _CachedText _timeText =
      _CachedText(20, color: settings.arenaAccent);
  late final _CachedText _promptText =
      _CachedText(20, color: settings.arenaAccent);
  late final _CachedText _fpsText =
      _CachedText(13, weight: FontWeight.w400, color: settings.arenaAccent);

  // The room's six surfaces as world-space quads, one variant per scenario
  // (CUBES: player at the front wall; FLOAT 360: player centered). Built once.
  static final List<List<(double, double, double)>> _wallsCubes =
      _buildWalls(kRoomFront, kRoomBack);
  static final List<List<(double, double, double)>> _wallsFloat =
      _buildWalls(-kFloatHalfD, kFloatHalfD);

  static List<List<(double, double, double)>> _buildWalls(
      double zf, double zb) {
    const double w = kRoomHalfW, f = kRoomFloor, c = kRoomCeil;
    return [
      [(-w, f, zf), (w, f, zf), (w, f, zb), (-w, f, zb)], // floor
      [(-w, c, zf), (w, c, zf), (w, c, zb), (-w, c, zb)], // ceiling
      [(-w, f, zf), (-w, f, zb), (-w, c, zb), (-w, c, zf)], // left wall
      [(w, f, zf), (w, f, zb), (w, c, zb), (w, c, zf)], // right wall
      [(-w, f, zb), (w, f, zb), (w, c, zb), (-w, c, zb)], // target wall
      [(-w, f, zf), (w, f, zf), (w, c, zf), (-w, c, zf)], // behind player
    ];
  }

  /// Fog-shaded room surfaces: clip each quad against the near plane, then
  /// fill with per-vertex colors (GPU-interpolated; no shader allocation).
  void _paintWalls(Canvas canvas, Size size) {
    final double cx = size.width / 2, cy = size.height / 2, fo = game.focal;
    final List<List<(double, double, double)>> walls =
        game.scenario == 0 ? _wallsCubes : _wallsFloat;
    for (final List<(double, double, double)> wall in walls) {
      final List<(double, double, double)> cam = [
        for (final (double x, double y, double z) in wall)
          game.toCamera(x, y, z)
      ];
      // Sutherland-Hodgman clip against z = kNearPlane.
      final List<(double, double, double)> poly = [];
      for (int i = 0; i < cam.length; i++) {
        final (double, double, double) a = cam[i];
        final (double, double, double) b = cam[(i + 1) % cam.length];
        final bool aIn = a.$3 > kNearPlane, bIn = b.$3 > kNearPlane;
        if (aIn) poly.add(a);
        if (aIn != bIn) {
          final double t = (kNearPlane - a.$3) / (b.$3 - a.$3);
          poly.add((
            a.$1 + (b.$1 - a.$1) * t,
            a.$2 + (b.$2 - a.$2) * t,
            kNearPlane,
          ));
        }
      }
      if (poly.length < 3) continue;
      final List<Offset> pts = [];
      final List<Color> cols = [];
      for (final (double x, double y, double z) in poly) {
        pts.add(Offset(cx + fo * x / z, cy - fo * y / z));
        // Rotation preserves distance, so camera-space length is world
        // distance from the eye — rotation-stable fog.
        final double d = math.sqrt(x * x + y * y + z * z);
        cols.add(Color.lerp(_fogNear, _fogFar, ((d - 2) / 14).clamp(0, 1))!);
      }
      canvas.drawVertices(
        ui.Vertices(ui.VertexMode.triangleFan, pts, colors: cols),
        BlendMode.dst,
        _wallPaint,
      );
    }
  }

  static final Paint _wallPaint = Paint();

  // The room: just its 12 edges as world-space segments, per scenario.
  static final List<(double, double, double, double, double, double)>
      _roomCubes = _buildRoom(kRoomFront, kRoomBack);
  static final List<(double, double, double, double, double, double)>
      _roomFloat = _buildRoom(-kFloatHalfD, kFloatHalfD);

  static List<(double, double, double, double, double, double)> _buildRoom(
      double zf, double zb) {
    const double w = kRoomHalfW, f = kRoomFloor, c = kRoomCeil;
    final lines = <(double, double, double, double, double, double)>[];
    for (final (double y1, double y2) in [(f, f), (c, c)]) {
      lines.add((-w, y1, zf, w, y2, zf));
      lines.add((-w, y1, zb, w, y2, zb));
      lines.add((-w, y1, zf, -w, y2, zb));
      lines.add((w, y1, zf, w, y2, zb));
    }
    for (final double x in [-w, w]) {
      lines.add((x, f, zf, x, c, zf));
      lines.add((x, f, zb, x, c, zb));
    }
    return lines;
  }

  // Cube faces: outward normal axis (0=x,1=y,2=z), sign, and the four corner
  // indices (bit layout: x<<2 | y<<1 | z).
  static const List<(int, double, int, int, int, int)> _faces = [
    (0, 1, 4, 5, 7, 6),
    (0, -1, 0, 1, 3, 2),
    (1, 1, 2, 3, 7, 6),
    (1, -1, 0, 1, 5, 4),
    (2, 1, 1, 3, 7, 5),
    (2, -1, 0, 2, 6, 4),
  ];

  void _worldLine(Canvas canvas, Size size, double ax, double ay, double az,
      double bx, double by, double bz, Paint paint) {
    var (x1, y1, z1) = game.toCamera(ax, ay, az);
    var (x2, y2, z2) = game.toCamera(bx, by, bz);
    if (z1 <= kNearPlane && z2 <= kNearPlane) return;
    // Clip the behind-camera endpoint to the near plane.
    if (z1 <= kNearPlane) {
      final double f = (kNearPlane - z1) / (z2 - z1);
      x1 += (x2 - x1) * f;
      y1 += (y2 - y1) * f;
      z1 = kNearPlane;
    } else if (z2 <= kNearPlane) {
      final double f = (kNearPlane - z2) / (z1 - z2);
      x2 += (x1 - x2) * f;
      y2 += (y1 - y2) * f;
      z2 = kNearPlane;
    }
    final double cx = size.width / 2, cy = size.height / 2, fo = game.focal;
    canvas.drawLine(
      Offset(cx + fo * x1 / z1, cy - fo * y1 / z1),
      Offset(cx + fo * x2 / z2, cy - fo * y2 / z2),
      paint,
    );
  }

  /// Convex quad with rounded corners (radius relative to its shortest edge).
  static Path _roundedQuad(List<Offset> p) {
    double minLen = double.infinity;
    for (int i = 0; i < 4; i++) {
      final double len = (p[(i + 1) % 4] - p[i]).distance;
      if (len < minLen) minLen = len;
    }
    final double r = minLen * 0.25;
    final Path path = Path();
    for (int i = 0; i < 4; i++) {
      final Offset prev = p[(i + 3) % 4];
      final Offset cur = p[i];
      final Offset next = p[(i + 1) % 4];
      final Offset inV = cur - prev;
      final Offset outV = next - cur;
      final double inLen = inV.distance, outLen = outV.distance;
      if (inLen < 1e-3 || outLen < 1e-3) continue;
      final Offset a = cur - inV / inLen * math.min(r, inLen / 2);
      final Offset b = cur + outV / outLen * math.min(r, outLen / 2);
      if (i == 0) {
        path.moveTo(a.dx, a.dy);
      } else {
        path.lineTo(a.dx, a.dy);
      }
      path.quadraticBezierTo(cur.dx, cur.dy, b.dx, b.dy);
    }
    path.close();
    return path;
  }

  void _paintCube(Canvas canvas, Size size, TargetCube t) {
    final double h = game.halfOf(t);
    if (h <= 0.01) return;
    final List<Offset> pts = List.filled(8, Offset.zero);
    final double cx = size.width / 2, cy = size.height / 2, fo = game.focal;
    for (int i = 0; i < 8; i++) {
      final double wx = t.x + ((i & 4) != 0 ? h : -h);
      final double wy = t.y + ((i & 2) != 0 ? h : -h);
      final double wz = t.z + ((i & 1) != 0 ? h : -h);
      final (double px, double py, double pz) = game.toCamera(wx, wy, wz);
      if (pz <= kNearPlane) return; // cube partly behind camera: skip
      pts[i] = Offset(cx + fo * px / pz, cy - fo * py / pz);
    }
    for (final (int axis, double sign, int a, int b, int c, int d) in _faces) {
      // Visible when the camera (at the origin) is on the normal's side.
      final double centerOnAxis = switch (axis) {
        0 => t.x,
        1 => t.y,
        _ => t.z,
      };
      if (sign * centerOnAxis + h >= 0) continue;
      // Fake lighting: face brightness by orientation.
      _cubeFill.color = switch ((axis, sign > 0)) {
        (2, false) => settings.targetColor, // facing the player
        (1, true) => _shadeTop,
        (1, false) => _shadeBottom,
        _ => _shadeSide,
      };
      final Path face =
          _roundedQuad([pts[a], pts[b], pts[c], pts[d]]);
      canvas.drawPath(face, _cubeFill);
      canvas.drawPath(face, _cubeEdge);
    }
  }

  /// FLOAT 360 target: shaded ball — dark base with an offset highlight
  /// clipped to the silhouette.
  void _paintSphere(Canvas canvas, Size size) {
    final (double px, double py, double pz) =
        game.toCamera(game.sphereX, game.sphereY, game.sphereZ);
    if (pz <= kNearPlane) return;
    final double cx = size.width / 2, cy = size.height / 2;
    final double r = game.focal * kSphereR / pz;
    final Offset c = Offset(cx + game.focal * px / pz, cy - game.focal * py / pz);
    final Path silhouette = Path()
      ..addOval(Rect.fromCircle(center: c, radius: r));
    canvas.save();
    canvas.clipPath(silhouette);
    canvas.drawCircle(c, r, Paint()..color = _shadeBottom);
    canvas.drawCircle(
      c + Offset(-r * 0.28, -r * 0.28),
      r * 0.85,
      Paint()..color = settings.targetColor,
    );
    canvas.restore();
    canvas.drawPath(silhouette, _cubeEdge);
  }

  /// REACTIVE target: capsule rendered as a round-capped line — body in a
  /// darker shade with an offset lit core, dark silhouette outline.
  void _paintPill(Canvas canvas, Size size) {
    final (double x1, double y1, double z1) =
        game.toCamera(game.rpX, kPillYC + kPillHalfH, game.rpZ);
    final (double x2, double y2, double z2) =
        game.toCamera(game.rpX, kPillYC - kPillHalfH, game.rpZ);
    if (z1 <= kNearPlane || z2 <= kNearPlane) return;
    final double cx = size.width / 2, cy = size.height / 2, fo = game.focal;
    final Offset top = Offset(cx + fo * x1 / z1, cy - fo * y1 / z1);
    final Offset bottom = Offset(cx + fo * x2 / z2, cy - fo * y2 / z2);
    final double r = fo * kPillR * 2 / (z1 + z2);
    canvas.drawLine(
      top,
      bottom,
      Paint()
        ..color = settings.arenaBg
        ..strokeWidth = 2 * r + 4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      top,
      bottom,
      Paint()
        ..color = _shadeBottom
        ..strokeWidth = 2 * r
        ..strokeCap = StrokeCap.round,
    );
    final Offset lift = Offset(-r * 0.22, -r * 0.22);
    canvas.drawLine(
      top + lift,
      bottom + lift,
      Paint()
        ..color = settings.targetColor
        ..strokeWidth = 2 * r * 0.6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    game.arena = size;
    canvas.drawRect(Offset.zero & size, _bgPaint);
    _paintWalls(canvas, size);

    // The room: just its edge lines, no surface tiling.
    for (final (double ax, double ay, double az, double bx, double by,
        double bz) in (game.scenario == 0 ? _roomCubes : _roomFloat)) {
      _worldLine(canvas, size, ax, ay, az, bx, by, bz, _edgePaint);
    }

    final double cx = size.width / 2, cy = size.height / 2;

    if (settings.showFps && game.fps > 0) {
      final TextPainter fps = _fpsText.of('${game.fps.round()} FPS');
      fps.paint(canvas, Offset(20, size.height - fps.height - 16));
    }

    if (!game.started) {
      final TextPainter tp = _promptText.of('PRESS FIRE TO START');
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2 - 70));
    }

    if (game.scenario == 1) {
      _paintSphere(canvas, size);
    } else if (game.scenario == 2) {
      _paintPill(canvas, size);
    } else {
      // Targets, far-to-near (they share a wall plane, so center-distance
      // ordering is fine).
      final List<TargetCube> ordered = List.of(game.targets)
        ..sort((a, b) {
          final double da = a.x * a.x + a.y * a.y + a.z * a.z;
          final double db = b.x * b.x + b.y * b.y + b.z * b.z;
          return db.compareTo(da);
        });
      for (final TargetCube t in ordered) {
        _paintCube(canvas, size, t);
      }
    }

    // Crosshair per player settings.
    final Offset center = Offset(cx, cy);
    drawCrosshair(canvas, center, settings);

    // X-shaped hit marker after a kill: crosshair color, half its size.
    if (game.hitT > 0) {
      final double r1 =
          (6 + settings.crosshairLength) * 0.5 * settings.crosshairScale;
      final double r0 = r1 * 0.35;
      for (final (double dx, double dy) in [
        (1.0, 1.0),
        (-1.0, 1.0),
        (1.0, -1.0),
        (-1.0, -1.0)
      ]) {
        final Offset dir = Offset(dx, dy) / math.sqrt2;
        canvas.drawLine(center + dir * r0, center + dir * r1, _fxStroke);
      }
    }

    // HUD: time bar, score top-left, clock top-center, pause top-right.
    final double frac = game.timeLeft / kRoundSeconds;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * frac, 4), _accentFill);
    final TextPainter score = _scoreText.of('${game.stats.score}');
    score.paint(canvas, const Offset(20, 18));
    final TextPainter time = _timeText.of(game.timeLeft.ceil().toString());
    time.paint(canvas, Offset((size.width - time.width) / 2, 18));

    _paintPauseButton(canvas);
    _paintFireButton(canvas);
  }

  void _paintPauseButton(Canvas canvas) {
    final Rect r = game.pauseRect;
    final Paint bar = Paint()..color = settings.arenaAccent;
    const double barW = 6, barH = 22;
    final Offset c = r.center;
    canvas.drawRect(
        Rect.fromCenter(
            center: c - const Offset(6.5, 0), width: barW, height: barH),
        bar);
    canvas.drawRect(
        Rect.fromCenter(
            center: c + const Offset(6.5, 0), width: barW, height: barH),
        bar);
  }

  void _paintFireButton(Canvas canvas) {
    final double op = game.fireOpacity.clamp(0.0, 1.0);
    if (op <= 0.01) return; // fully transparent: invisible but still tappable
    drawFireButton(canvas, game.fireCenter, game.fireR, op);
  }

  @override
  bool shouldRepaint(_GamePainter oldDelegate) =>
      oldDelegate.game != game ||
      oldDelegate._cubeFill.color != _cubeFill.color;
}

// ---------------------------------------------------------------------------
// Static screens — zero animation, zero CPU while idle.
// ---------------------------------------------------------------------------
ButtonStyle _buttonStyle() => OutlinedButton.styleFrom(
      foregroundColor: kFg,
      side: const BorderSide(color: kFg, width: 2),
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
      textStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: 4,
      ),
      shape: const RoundedRectangleBorder(),
    );

TextStyle _fgStyle(double size,
        {FontWeight weight = FontWeight.w600, double spacing = 2}) =>
    TextStyle(
      color: kFg,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: spacing,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

class _MenuScreen extends StatelessWidget {
  const _MenuScreen({
    required this.best,
    required this.scenario,
    required this.onScenario,
    required this.onStart,
    required this.onProfile,
    required this.onSettings,
  });

  final int best;
  final int scenario;
  final ValueChanged<int> onScenario;
  final VoidCallback onStart;
  final VoidCallback onProfile;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Crosshair(size: 72),
          const SizedBox(height: 28),
          Text('AIM TRAINER',
              style: _fgStyle(34, weight: FontWeight.w800, spacing: 8)),
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RankBadge(rank: rankFor(best), size: 24),
              const SizedBox(width: 10),
              Text('BEST  $best', style: _fgStyle(16)),
            ],
          ),
          const SizedBox(height: 36),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () => onScenario(
                    (scenario - 1 + kScenarios.length) % kScenarios.length),
                icon: const Icon(Icons.chevron_left, color: kFg),
              ),
              SizedBox(
                width: 160,
                child: Text(
                  kScenarios[scenario],
                  textAlign: TextAlign.center,
                  style: _fgStyle(18, spacing: 6),
                ),
              ),
              IconButton(
                onPressed: () =>
                    onScenario((scenario + 1) % kScenarios.length),
                icon: const Icon(Icons.chevron_right, color: kFg),
              ),
            ],
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            style: _buttonStyle(),
            onPressed: onStart,
            child: const Text('START'),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: onProfile,
                child: Text('PROFILE',
                    style: _fgStyle(13, weight: FontWeight.w500, spacing: 4)),
              ),
              const SizedBox(width: 16),
              TextButton(
                onPressed: onSettings,
                child: Text('SETTINGS',
                    style: _fgStyle(13, weight: FontWeight.w500, spacing: 4)),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'SWIPE TO AIM — TAP FIRE TO SHOOT',
            style: _fgStyle(12, weight: FontWeight.w400, spacing: 3),
          ),
        ],
      ),
    );
  }
}

class _SettingsScreen extends StatelessWidget {
  const _SettingsScreen({
    required this.onCrosshair,
    required this.onColors,
    required this.onGeneral,
    required this.onHud,
    required this.onBack,
  });

  final VoidCallback onCrosshair;
  final VoidCallback onColors;
  final VoidCallback onGeneral;
  final VoidCallback onHud;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    Widget section(String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: SizedBox(
            width: 280,
            child: OutlinedButton(
              style: _buttonStyle(),
              onPressed: onTap,
              child: Text(label),
            ),
          ),
        );

    return SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text('SETTINGS', style: _fgStyle(24, spacing: 8)),
              const SizedBox(height: 28),
              section('CROSSHAIR', onCrosshair),
              section('COLORS', onColors),
              section('HUD', onHud),
              section('GENERAL', onGeneral),
              const SizedBox(height: 10),
              TextButton(
                onPressed: onBack,
                child: Text('BACK',
                    style: _fgStyle(14, weight: FontWeight.w500, spacing: 4)),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// Shared widgets for the settings sub-screens. ------------------------------

Widget _settingsLabel(String s) =>
    Text(s, style: _fgStyle(13, weight: FontWeight.w400, spacing: 4));

Widget _settingsSlider(
    double value, double min, double max, ValueChanged<double> set) {
  return SliderTheme(
    data: SliderThemeData(
      activeTrackColor: kFg,
      inactiveTrackColor: kFg.withValues(alpha: .2),
      thumbColor: kFg,
      overlayColor: kFg.withValues(alpha: .12),
      trackHeight: 2,
    ),
    child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: set),
  );
}

Widget _settingsSliderRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [_settingsLabel(label), Text(value, style: _fgStyle(13))],
    ),
  );
}

/// A back bar used by every sub-screen.
Widget _settingsHeader(String title, VoidCallback onBack) {
  return Row(
    children: [
      IconButton(
        onPressed: onBack,
        icon: const Icon(Icons.chevron_left, color: kFg, size: 30),
      ),
      Expanded(
        child: Center(child: Text(title, style: _fgStyle(18, spacing: 6))),
      ),
      const SizedBox(width: 46), // balance the back button
    ],
  );
}

/// Full RGB color editor: preview swatch plus three channel sliders.
class _RgbPicker extends StatelessWidget {
  const _RgbPicker({
    required this.label,
    required this.color,
    required this.onPick,
  });

  final String label;
  final Color color;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    final int r = (color.r * 255).round();
    final int g = (color.g * 255).round();
    final int b = (color.b * 255).round();

    Widget channel(String name, int v, Color Function(int) compose) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            SizedBox(width: 16, child: Text(name, style: _fgStyle(12))),
            Expanded(
              child: _settingsSlider(
                  v.toDouble(), 0, 255, (nv) => onPick(compose(nv.round()))),
            ),
            SizedBox(
                width: 34,
                child: Text('$v',
                    textAlign: TextAlign.right, style: _fgStyle(12))),
          ],
        ),
      );
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _settingsLabel(label),
            const SizedBox(width: 12),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: kFg.withValues(alpha: .35)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        channel('R', r, (v) => Color.fromARGB(255, v, g, b)),
        channel('G', g, (v) => Color.fromARGB(255, r, v, b)),
        channel('B', b, (v) => Color.fromARGB(255, r, g, v)),
      ],
    );
  }
}

// Crosshair section: pinned live preview, everything crosshair in one place.
class _CrosshairSettingsScreen extends StatelessWidget {
  const _CrosshairSettingsScreen({
    required this.settings,
    required this.onChanged,
    required this.onBack,
  });

  final AppSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final AppSettings s = settings;
    return SafeArea(
      child: Column(
        children: [
          _settingsHeader('CROSSHAIR', onBack),
          // Preview stays pinned while the controls scroll beneath it.
          Container(
            width: 220,
            height: 72,
            decoration: BoxDecoration(
              color: s.arenaBg,
              border: Border.all(color: kFg.withValues(alpha: .25)),
            ),
            child: CustomPaint(
              painter: _CrosshairPreviewPainter(
                s.crosshairColor,
                s.crosshairDot,
                s.crosshairLength,
                s.crosshairWidth,
                s.crosshairBorder,
                s.crosshairBorderColor,
                s.crosshairScale,
                s,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    children: [
                      _settingsSliderRow(
                          'SCALE', '${(s.crosshairScale * 100).round()}%'),
                      _settingsSlider(s.crosshairScale, 0.5, 2.5, (v) {
                        s.crosshairScale = v;
                        onChanged();
                      }),
                      _settingsSliderRow(
                          'CENTER DOT SIZE', s.crosshairDot.toStringAsFixed(1)),
                      _settingsSlider(s.crosshairDot, 0, 8, (v) {
                        s.crosshairDot = v;
                        onChanged();
                      }),
                      _settingsSliderRow(
                          'LENGTH', s.crosshairLength.toStringAsFixed(0)),
                      _settingsSlider(s.crosshairLength, 0, 30, (v) {
                        s.crosshairLength = v;
                        onChanged();
                      }),
                      _settingsSliderRow(
                          'WIDTH', s.crosshairWidth.toStringAsFixed(1)),
                      _settingsSlider(s.crosshairWidth, 1, 8, (v) {
                        s.crosshairWidth = v;
                        onChanged();
                      }),
                      _settingsSliderRow('BORDER THICKNESS',
                          s.crosshairBorder.toStringAsFixed(1)),
                      _settingsSlider(s.crosshairBorder, 0, 4, (v) {
                        s.crosshairBorder = v;
                        onChanged();
                      }),
                      const SizedBox(height: 12),
                      _RgbPicker(
                        label: 'CROSSHAIR COLOR',
                        color: s.crosshairColor,
                        onPick: (c) {
                          s.crosshairColor = c;
                          onChanged();
                        },
                      ),
                      const SizedBox(height: 16),
                      _RgbPicker(
                        label: 'BORDER COLOR',
                        color: s.crosshairBorderColor,
                        onPick: (c) {
                          s.crosshairBorderColor = c;
                          onChanged();
                        },
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Colors section: target and arena colors, each fully RGB-adjustable.
class _ColorsSettingsScreen extends StatelessWidget {
  const _ColorsSettingsScreen({
    required this.settings,
    required this.onChanged,
    required this.onBack,
  });

  final AppSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final AppSettings s = settings;
    return SafeArea(
      child: Column(
        children: [
          _settingsHeader('COLORS', onBack),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      _RgbPicker(
                        label: 'TARGET COLOR',
                        color: s.targetColor,
                        onPick: (c) {
                          s.targetColor = c;
                          onChanged();
                        },
                      ),
                      const SizedBox(height: 16),
                      _RgbPicker(
                        label: 'ARENA BACKGROUND',
                        color: s.arenaBg,
                        onPick: (c) {
                          s.arenaBg = c;
                          onChanged();
                        },
                      ),
                      const SizedBox(height: 16),
                      _RgbPicker(
                        label: 'ARENA ACCENT',
                        color: s.arenaAccent,
                        onPick: (c) {
                          s.arenaAccent = c;
                          onChanged();
                        },
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// General section: sensitivity and diagnostics.
class _GeneralSettingsScreen extends StatelessWidget {
  const _GeneralSettingsScreen({
    required this.settings,
    required this.onChanged,
    required this.onBack,
  });

  final AppSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final AppSettings s = settings;
    return SafeArea(
      child: Column(
        children: [
          _settingsHeader('GENERAL', onBack),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      _settingsSliderRow(
                          'SENSITIVITY', '${s.sensitivity.toStringAsFixed(1)}X'),
                      _settingsSlider(s.sensitivity, 0.4, 2.4, (v) {
                        s.sensitivity = v;
                        onChanged();
                      }),
                      _settingsSliderRow('FOV', '${s.fov.round()}°'),
                      _settingsSlider(s.fov, 40, 120, (v) {
                        s.fov = v;
                        onChanged();
                      }),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _settingsLabel('FPS COUNTER'),
                            GestureDetector(
                              onTap: () {
                                s.showFps = !s.showFps;
                                onChanged();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 8),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: s.showFps
                                        ? kFg
                                        : kFg.withValues(alpha: .35),
                                    width: s.showFps ? 2 : 1,
                                  ),
                                ),
                                child: Text(s.showFps ? 'ON' : 'OFF',
                                    style: _fgStyle(13)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HUD editor — drag the FIRE button anywhere; sliders for size and opacity.
// Future HUD buttons get edited here the same way.
// ---------------------------------------------------------------------------
class _HudEditScreen extends StatefulWidget {
  const _HudEditScreen({
    required this.settings,
    required this.onChanged,
    required this.onBack,
  });

  final AppSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onBack;

  @override
  State<_HudEditScreen> createState() => _HudEditScreenState();
}

class _HudEditScreenState extends State<_HudEditScreen> {
  Widget _sliderRow(String label, String value, double v, double min,
      double max, ValueChanged<double> set) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          SizedBox(
              width: 90,
              child: Text(label,
                  style: _fgStyle(11, weight: FontWeight.w400, spacing: 2))),
          Expanded(
            child: _settingsSlider(v, min, max, (nv) {
              set(nv);
              setState(() {});
              widget.onChanged();
            }),
          ),
          SizedBox(width: 44, child: Text(value, style: _fgStyle(11))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings s = widget.settings;
    final Size size = MediaQuery.sizeOf(context);
    final double r =
        (size.shortestSide * 0.115 * s.fireScale).clamp(28.0, 200.0);
    final Offset c = (s.fireX < 0 || s.fireY < 0)
        ? Offset(size.width - r - 26, size.height - r - 30)
        : Offset(
            (s.fireX * size.width).clamp(r, size.width - r),
            (s.fireY * size.height).clamp(r, size.height - r),
          );
    // Keep the button findable in the editor even at zero opacity.
    final double op = math.max(s.fireOpacity, 0.25);

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: Container(color: kBg)),
        // The draggable FIRE button.
        Positioned(
          left: c.dx - r,
          top: c.dy - r,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) {
              setState(() {
                s.fireX = ((c.dx + d.delta.dx) / size.width).clamp(0.0, 1.0);
                s.fireY = ((c.dy + d.delta.dy) / size.height).clamp(0.0, 1.0);
              });
            },
            onPanEnd: (_) => widget.onChanged(),
            child: CustomPaint(
              size: Size.square(r * 2),
              painter: _FireButtonPreviewPainter(op),
            ),
          ),
        ),
        // Control panel.
        SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              Text('CUSTOMISE HUD', style: _fgStyle(18, spacing: 6)),
              const SizedBox(height: 6),
              Text('DRAG THE FIRE BUTTON TO MOVE IT',
                  style: _fgStyle(11, weight: FontWeight.w400, spacing: 2)),
              const SizedBox(height: 12),
              _sliderRow('SIZE', '${(s.fireScale * 100).round()}%',
                  s.fireScale, 0.6, 1.8, (v) => s.fireScale = v),
              _sliderRow('OPACITY', '${(s.fireOpacity * 100).round()}%',
                  s.fireOpacity, 0.0, 1.0, (v) => s.fireOpacity = v),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        s.fireX = -1;
                        s.fireY = -1;
                        s.fireScale = 1.0;
                        s.fireOpacity = 1.0;
                      });
                      widget.onChanged();
                    },
                    child: Text('RESET',
                        style:
                            _fgStyle(13, weight: FontWeight.w500, spacing: 4)),
                  ),
                  const SizedBox(width: 24),
                  TextButton(
                    onPressed: widget.onBack,
                    child: Text('DONE',
                        style:
                            _fgStyle(13, weight: FontWeight.w500, spacing: 4)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FireButtonPreviewPainter extends CustomPainter {
  _FireButtonPreviewPainter(this.opacity);

  final double opacity;

  @override
  void paint(Canvas canvas, Size size) => drawFireButton(
      canvas, size.center(Offset.zero), size.shortestSide / 2, opacity);

  @override
  bool shouldRepaint(_FireButtonPreviewPainter oldDelegate) =>
      oldDelegate.opacity != opacity;
}

class _CrosshairPreviewPainter extends CustomPainter {
  // The value fields exist only so shouldRepaint can detect changes to the
  // (mutable, shared) settings object between frames.
  _CrosshairPreviewPainter(this.color, this.dot, this.length, this.width,
      this.border, this.borderColor, this.scale, this.settings);

  final Color color;
  final double dot;
  final double length;
  final double width;
  final double border;
  final Color borderColor;
  final double scale;
  final AppSettings settings;

  @override
  void paint(Canvas canvas, Size size) {
    drawCrosshair(canvas, size.center(Offset.zero), settings);
  }

  @override
  bool shouldRepaint(_CrosshairPreviewPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dot != dot ||
      oldDelegate.length != length ||
      oldDelegate.width != width ||
      oldDelegate.border != border ||
      oldDelegate.borderColor != borderColor ||
      oldDelegate.scale != scale;
}

class _ResultsScreen extends StatelessWidget {
  const _ResultsScreen({
    required this.stats,
    required this.best,
    required this.onReplay,
    required this.onMenu,
  });

  final RoundStats stats;
  final int best;
  final VoidCallback onReplay;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final bool isBest = stats.score >= best && stats.score > 0;
    final Rank? rank = rankFor(stats.score);
    final Rank? next = nextRankFor(stats.score);
    return SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 20),
              Text(isBest ? 'NEW BEST' : 'ROUND OVER',
                  style: _fgStyle(18, spacing: 6)),
              const SizedBox(height: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RankBadge(rank: rank, size: 64),
                  const SizedBox(width: 20),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${stats.score}',
                          style: _fgStyle(54, weight: FontWeight.w800)),
                      Text(
                        rank?.name ?? 'UNRANKED',
                        style: TextStyle(
                          color: rank?.color ?? kFg.withValues(alpha: .5),
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 5,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (next != null) ...[
                const SizedBox(height: 8),
                Text('NEXT: ${next.name} AT ${next.threshold}',
                    style: _fgStyle(12, weight: FontWeight.w400, spacing: 3)),
              ],
              const SizedBox(height: 20),
              _statRow('HITS', '${stats.hits}'),
              _statRow('MISSES', '${stats.misses}'),
              _statRow(
                  'ACCURACY', '${(stats.accuracy * 100).toStringAsFixed(0)}%'),
              _statRow('AVG KILL', '${stats.avgKillMs.toStringAsFixed(0)} MS'),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    style: _buttonStyle(),
                    onPressed: onReplay,
                    child: const Text('AGAIN'),
                  ),
                  const SizedBox(width: 20),
                  OutlinedButton(
                    style: _buttonStyle(),
                    onPressed: onMenu,
                    child: const Text('MENU'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        width: 260,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: _fgStyle(14, weight: FontWeight.w400)),
            Text(value, style: _fgStyle(14)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profile — rank and best score for every scenario.
// ---------------------------------------------------------------------------
class _ProfileScreen extends StatelessWidget {
  const _ProfileScreen({required this.bests, required this.onBack});

  final Map<int, int> bests;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _settingsHeader('PROFILE', onBack),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      for (int i = 0; i < kScenarios.length; i++)
                        _scenarioCard(i),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scenarioCard(int i) {
    final int best = bests[i] ?? 0;
    final Rank? rank = rankFor(best);
    final Rank? next = nextRankFor(best);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: kFg.withValues(alpha: .3)),
      ),
      child: Row(
        children: [
          RankBadge(rank: rank, size: 64),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(kScenarios[i], style: _fgStyle(18, spacing: 5)),
                const SizedBox(height: 4),
                Text(
                  rank?.name ?? 'UNRANKED',
                  style: TextStyle(
                    color: rank?.color ?? kFg.withValues(alpha: .5),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  next == null
                      ? 'BEST $best — TOP RANK'
                      : 'BEST $best — NEXT ${next.name} AT ${next.threshold}',
                  style: _fgStyle(11, weight: FontWeight.w400, spacing: 2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Crosshair extends StatelessWidget {
  const _Crosshair({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _CrosshairPainter());
  }
}

class _CrosshairPainter extends CustomPainter {
  static final Paint _stroke = Paint()
    ..color = kFg
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2 - 2;
    canvas.drawCircle(c, r * 0.72, _stroke);
    canvas.drawCircle(c, r * 0.08, Paint()..color = kFg);
    for (final double a in [0, math.pi / 2, math.pi, 3 * math.pi / 2]) {
      final Offset dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * (r * 0.45), c + dir * r, _stroke);
    }
  }

  @override
  bool shouldRepaint(_CrosshairPainter oldDelegate) => false;
}
