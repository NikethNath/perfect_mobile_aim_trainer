import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
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
const double kLookSens = 0.0042; // radians per logical pixel of swipe
const double kPitchLimit = 1.1; // radians
const double kNearPlane = 0.2;
// Bot target sizes/room are now tunable per scenario; see kTuneParams.

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
  // Android keeps apps at 60Hz unless they explicitly request a faster
  // display mode; ask for the highest the panel supports (90/120/144Hz).
  // No-op on iOS, where ProMotion is unlocked via Info.plist instead.
  if (Platform.isAndroid) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (_) {
      // Device doesn't support mode switching; stay at default.
    }
  }
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
      title: 'Aim Ranked',
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
  play,
  tuning,
  profile,
  ranks,
  settings,
  settingsCrosshair,
  settingsColors,
  settingsGeneral,
  hudEdit,
  playing,
  results,
}

const List<String> kScenarios = ['CUBES', 'FLOAT 360', 'REACTIVE'];

const List<String> kScenarioDesc = [
  'Flick between static cubes on the far wall. Pure target switching, '
      'precision and click timing.',
  'Track a single sphere drifting around you in full 360°. Smooth tracking '
      'and movement reading.',
  'Track a strafing bot that jukes left/right and pushes in and out. '
      'Reactive tracking under pressure.',
];

// ---------------------------------------------------------------------------
// Bot tuning parameters. Each is a live, persisted slider grouped by scenario
// (1 = FLOAT 360, 2 = REACTIVE). Dial them in the Tuning menu, then read the
// values back here to bake in a final default.
// ---------------------------------------------------------------------------
class TuneParam {
  const TuneParam(
      this.scenario, this.key, this.label, this.min, this.max, this.def);
  final int scenario;
  final String key;
  final String label;
  final double min;
  final double max;
  final double def;
}

const List<TuneParam> kTuneParams = [
  // FLOAT 360
  TuneParam(1, 'fl_orbit', 'ORBIT SPEED', 0.5, 4.0, 1.6),
  TuneParam(1, 'fl_vert', 'VERTICAL SPEED', 0.0, 1.5, 0.65),
  TuneParam(1, 'fl_depth', 'DEPTH SPEED', 0.0, 4.0, 2.6),
  TuneParam(1, 'fl_chmin', 'CHANGE MIN (S)', 0.1, 2.0, 0.15),
  TuneParam(1, 'fl_chrange', 'CHANGE SPREAD (S)', 0.0, 2.0, 0.65),
  TuneParam(1, 'fl_accel', 'ACCELERATION', 0.5, 10.0, 4.3),
  TuneParam(1, 'fl_size', 'TARGET SIZE', 0.1, 0.7, 0.33),
  TuneParam(1, 'fl_distmin', 'MIN DISTANCE', 2.0, 8.0, 4.7),
  TuneParam(1, 'fl_distmax', 'MAX DISTANCE', 2.0, 8.0, 7.1),
  // REACTIVE
  TuneParam(2, 're_strafe', 'STRAFE SPEED', 1.0, 12.0, 8.6),
  TuneParam(2, 're_depth', 'DEPTH SPEED', 0.0, 8.0, 6.4),
  TuneParam(2, 're_chmin', 'CHANGE MIN (S)', 0.05, 1.5, 0.15),
  TuneParam(2, 're_chrange', 'CHANGE SPREAD (S)', 0.0, 2.0, 0.35),
  TuneParam(2, 're_accel', 'ACCELERATION', 1.0, 15.0, 6.9),
  TuneParam(2, 're_size', 'TARGET RADIUS', 0.1, 0.6, 0.4),
  TuneParam(2, 're_height', 'TARGET HEIGHT', 0.4, 2.5, 1.26),
  TuneParam(2, 're_room', 'ROOM SIZE', 6.0, 24.0, 14.0),
  TuneParam(2, 're_distmin', 'MIN DISTANCE', 2.0, 14.0, 4.0),
  TuneParam(2, 're_distmax', 'MAX DISTANCE', 2.0, 18.0, 9.0),
];

final Map<String, double> kTuneDefaults = {
  for (final TuneParam p in kTuneParams) p.key: p.def
};

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

// Default trainer palette: black arena, red targets, white accents.
const Color kDefaultArenaBg = Color(0xFF000000);
const Color kDefaultTarget = Color(0xFFFF4757);
const Color kDefaultAccent = Color(0xFFFFFFFF);

class AppSettings {
  Color targetColor = kDefaultTarget;
  Color arenaBg = kDefaultArenaBg; // trainer background
  Color arenaAccent = kDefaultAccent; // trainer grid/HUD accent
  Color crosshairColor = kDefaultAccent;
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

  // Live bot-tuning values, keyed by TuneParam.key.
  final Map<String, double> tune = Map<String, double>.from(kTuneDefaults);

  double tv(String key) => tune[key] ?? kTuneDefaults[key]!;

  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    targetColor =
        Color(prefs.getInt('target_color') ?? kDefaultTarget.toARGB32());
    arenaBg = Color(prefs.getInt('arena_bg') ?? kDefaultArenaBg.toARGB32());
    arenaAccent =
        Color(prefs.getInt('arena_accent') ?? kDefaultAccent.toARGB32());
    crosshairColor =
        Color(prefs.getInt('crosshair_color') ?? kDefaultAccent.toARGB32());
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
    for (final TuneParam p in kTuneParams) {
      tune[p.key] = prefs.getDouble('tune_${p.key}') ?? p.def;
    }
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
    for (final TuneParam p in kTuneParams) {
      await prefs.setDouble('tune_${p.key}', tv(p.key));
    }
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

// Per-scenario score multiplier, indexed by scenario. Tracking modes
// (full-auto) are scaled so a Celestial-tier run (~60% uptime, full round)
// lands on the same ~400 as a Celestial CUBES run. See kRanks.
const List<double> kScoreScale = [1.0, 1.43, 1.43];

class RoundStats {
  int hits = 0;
  int misses = 0;
  double sumKillMs = 0;
  double scoreScale = 1.0; // set from kScoreScale at round start

  double get accuracy => hits + misses == 0 ? 0 : hits / (hits + misses);
  double get avgKillMs => hits == 0 ? 0 : sumKillMs / hits;

  /// Score formula: hits weighted by the square root of accuracy, then
  /// normalized per scenario so all modes share one rank ladder.
  int get score => (hits * math.sqrt(accuracy) * scoreScale).round();
}

// ---------------------------------------------------------------------------
// Rank ladder. Thresholds are on the hits*sqrt(accuracy) score.
// ---------------------------------------------------------------------------
class Rank {
  const Rank(this.name, this.threshold, this.color, this.blurb);

  final String name;
  final int threshold;
  final Color color;
  final String blurb;
}

const List<Rank> kRanks = [
  Rank('BRONZE', 20, Color(0xFFCD7F32),
      'Just starting out. Aim is mostly hope at this stage.'),
  Rank('SILVER', 40, Color(0xFFC8CDD4),
      'You hit targets... eventually. A long road ahead.'),
  Rank('GOLD', 62, Color(0xFFFFD24A),
      'Average phone-gamer aim. Functional, nothing more.'),
  Rank('PLATINUM', 88, Color(0xFF5CE1E6),
      'Slightly above average. The real grind starts here.'),
  Rank('DIAMOND', 118, Color(0xFFB9E8FF),
      "Decent. But 'good' is still a few tiers up."),
  Rank('EMERALD', 152, Color(0xFF2ECC71),
      'The dedicated grinder. Training is paying off — top ~10% territory.'),
  Rank('RUBY', 190, Color(0xFFE0356F),
      'Semi-competitive mechanics. Flicks and tracking are second nature.'),
  Rank('MASTER', 235, Color(0xFFB57BFF),
      'Elite. Tournament-grade aim under full pressure.'),
  Rank('GRANDMASTER', 290, Color(0xFFFF5C5C),
      'Feared. Among the best aimers on mobile, period.'),
  Rank('ASTRA', 350, Color(0xFF8FD0FF),
      "Approaching the human ceiling. Reflexes most people can't comprehend."),
  Rank('CELESTIAL', 400, Color(0xFFEFFBFF),
      'The summit. A handful of humans on Earth. Prove it.'),
];

// ---------------------------------------------------------------------------
// Tamper-evident best-score storage. Each best is written with an HMAC so a
// hand-edited prefs file (e.g. on a rooted device) fails verification and is
// rejected. This stops casual save-editing; it is not proof against someone
// who reverse-engineers the app to extract the key (see notes in chat).
// ---------------------------------------------------------------------------
const String _kScoreSecret =
    'aimranked.v1.7c1f9a2e-score-integrity-do-not-change';

String _scoreSig(String scenario, int value) =>
    Hmac(sha256, utf8.encode(_kScoreSecret))
        .convert(utf8.encode('$scenario:$value'))
        .toString();

int loadSignedBest(SharedPreferences prefs, String scenario) {
  final int? v = prefs.getInt('best_$scenario');
  if (v == null) return 0;
  final String? sig = prefs.getString('best_${scenario}_sig');
  // Missing or mismatched signature => unsigned/tampered => don't trust it.
  if (sig == null || sig != _scoreSig(scenario, v)) return 0;
  return v;
}

Future<void> saveSignedBest(
    SharedPreferences prefs, String scenario, int value) async {
  await prefs.setInt('best_$scenario', value);
  await prefs.setString('best_${scenario}_sig', _scoreSig(scenario, value));
}

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
          _bests[i] = loadSignedBest(prefs, kScenarios[i]);
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
      SharedPreferences.getInstance().then(
          (prefs) => saveSignedBest(prefs, kScenarios[_scenario], stats.score));
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
            topRank: rankFor(_bests.values.fold(0, (a, b) => math.max(a, b))),
            onPlay: () => setState(() => _screen = _Screen.play),
            onTuning: () => setState(() => _screen = _Screen.tuning),
            onProfile: () => setState(() => _screen = _Screen.profile),
            onRanks: () => setState(() => _screen = _Screen.ranks),
            onSettings: () => setState(() => _screen = _Screen.settings),
          ),
        _Screen.play => _PlayScreen(
            bests: _bests,
            onPick: (i) => setState(() {
              _scenario = i;
              _round++;
              _screen = _Screen.playing;
            }),
            onBack: () => setState(() => _screen = _Screen.menu),
          ),
        _Screen.tuning => _TuningScreen(
            settings: _settings,
            onChanged: _saveSettings,
            onBack: () => setState(() => _screen = _Screen.menu),
          ),
        _Screen.profile => _ProfileScreen(
            bests: _bests,
            onBack: () => setState(() => _screen = _Screen.menu),
          ),
        _Screen.ranks => _RanksScreen(
            current: rankFor(
                _bests.values.fold(0, (a, b) => math.max(a, b))),
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
  void Function()? onHit; // fired on a landed shot (for SFX)
  void Function()? onMiss; // fired on a missed shot (for SFX)
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

  // Bot tuning values, shared from AppSettings at round start.
  Map<String, double> tune = kTuneDefaults;
  double tv(String k) => tune[k] ?? kTuneDefaults[k]!;
  double get sphereR => tv('fl_size');
  double get pillR => tv('re_size');
  double get pillHalfH => tv('re_height');
  double get pillYC => kRoomFloor + pillHalfH + pillR;

  // REACTIVE arena geometry, rebuilt from the tunable room size at setup.
  List<List<(double, double, double)>> reactiveWalls = const [];
  List<(double, double, double, double, double, double)> reactiveRoom =
      const [];
  List<(double, double, double, double, double, double)> reactiveFloor =
      const [];

  /// Copy tuning from settings and (re)build geometry. Call at round start.
  void applyTuning(Map<String, double> t) {
    tune = t;
    final double w = tv('re_room');
    reactiveWalls = buildWalls(w, -w, w);
    reactiveRoom = buildRoom(w, -w, w);
    reactiveFloor = buildFloorGrid(w, -w, w, 2);
    sDist = (tv('fl_distmin') + tv('fl_distmax')) / 2;
    rDist = (tv('re_distmin') + tv('re_distmax')) / 2;
  }

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
  double rAz = 0, rDist = 7; // position (azimuth, distance)
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
      // Spawn them already grown (born in the past) so they stay full-size
      // through the first shot instead of collapsing to a zero-size pop-in.
      if (scenario == 0 && arena != Size.zero) {
        while (targets.length < kMaxTargets) {
          final TargetCube c = _spawn();
          targets.add(TargetCube(c.x, c.y, c.z, -kGrowTime));
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
      _retargetT = tv('fl_chmin') + _rng.nextDouble() * tv('fl_chrange');
      tAz = (_rng.nextDouble() * 2 - 1) * tv('fl_orbit'); // rad/s
      tEl = (_rng.nextDouble() * 2 - 1) * tv('fl_vert');
      tDist = (_rng.nextDouble() * 2 - 1) * tv('fl_depth');
    }
    // Ease current velocity toward the target velocity. Punchier acceleration
    // makes the sphere lunge into headings and brake harder.
    final double k = math.min(1, dt * tv('fl_accel'));
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
    final double dlo = math.min(tv('fl_distmin'), tv('fl_distmax'));
    final double dhi = math.max(tv('fl_distmin'), tv('fl_distmax'));
    if (sDist > dhi) {
      sDist = dhi;
      tDist = -tDist.abs();
    } else if (sDist < dlo) {
      sDist = dlo;
      tDist = tDist.abs();
    }
  }

  void _updateReactive(double dt) {
    _rRetargetT -= dt;
    if (_rRetargetT <= 0) {
      // Erratic legs: random duration means random strafe distances —
      // short jukes through committed runs. Strafe and depth are picked
      // with identical (uniform, symmetric) probability.
      _rRetargetT = tv('re_chmin') + _rng.nextDouble() * tv('re_chrange');
      final double topStrafe = tv('re_strafe'); // linear world units/s
      final double topDepth = tv('re_depth');
      // Strafe legs always commit to full speed — only the direction is
      // random, so the pill never dawdles at low velocity.
      rtS = (_rng.nextBool() ? 1 : -1) * topStrafe;
      rtD = (_rng.nextBool() ? 1 : -1) *
          (0.4 + _rng.nextDouble() * 0.6) *
          topDepth;
    }
    // Snappy easing: hits top speed (and stops) fast.
    final double k = math.min(1, dt * tv('re_accel'));
    rvS += (rtS - rvS) * k;
    rvD += (rtD - rvD) * k;
    rAz += rvS / rDist * dt; // constant linear strafe speed at any distance
    rDist += rvD * dt;
    final double dlo = math.min(tv('re_distmin'), tv('re_distmax'));
    final double dhi = math.max(tv('re_distmin'), tv('re_distmax'));
    if (rDist > dhi) {
      rDist = dhi;
      rtD = -rtD.abs();
    } else if (rDist < dlo) {
      rDist = dlo;
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
    if (ex * ex + ez * ez > pillR * pillR) return false;
    final double yAt = fy * t;
    final double yLo = pillYC - pillHalfH, yHi = pillYC + pillHalfH;
    if (yAt >= yLo && yAt <= yHi) return true;
    // Near an end: test the cap sphere.
    final double cy = yAt < yLo ? yLo : yHi;
    final double dot = rpX * fx + cy * fy + rpZ * fz;
    final double d2 = rpX * rpX + cy * cy + rpZ * rpZ - dot * dot;
    return dot > 0 && d2 <= pillR * pillR;
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
  void _registerHit(double bornClock) {
    stats.hits++;
    stats.sumKillMs += (clock - bornClock) * 1000;
    hitT = 0.18;
    HapticFeedback.lightImpact();
    onHit?.call();
  }

  void _registerMiss() {
    stats.misses++;
    onMiss?.call();
  }

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
        _registerHit(_lastHitClock);
        _lastHitClock = clock;
      } else {
        _registerMiss();
      }
      notifyListeners();
      return;
    }
    if (scenario == 1) {
      // Ray-sphere: does the forward ray pass within the sphere's radius?
      final (double cx, double cyy, double cz) =
          toCamera(sphereX, sphereY, sphereZ);
      if (cz > kNearPlane && math.sqrt(cx * cx + cyy * cyy) <= sphereR) {
        _registerHit(_lastHitClock);
        _lastHitClock = clock;
      } else {
        _registerMiss();
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
      _registerHit(t.born);
      targets.add(_spawn());
    } else {
      _registerMiss();
    }
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Low-latency SFX. The fix for full-auto frame drops: each clip is decoded
// ONCE up front (setSource), and a shot just rewinds + replays a preloaded
// player — no per-shot asset resolution or decode. A small round-robin lets
// rapid hits overlap. Fire-and-forget; errors swallowed. Hit=glass, miss=deeppop.
// ---------------------------------------------------------------------------
class SoundFx {
  static const String hitAsset = 'sounds/glass.ogg';
  static const String missAsset = 'sounds/deeppop.ogg';

  final List<AudioPlayer> _hit = [];
  final List<AudioPlayer> _miss = [];
  int _hi = 0;
  int _mi = 0;
  bool ready = false;

  Future<void> init() async {
    try {
      for (int i = 0; i < 4; i++) {
        _hit.add(await _make(hitAsset));
      }
      for (int i = 0; i < 3; i++) {
        _miss.add(await _make(missAsset));
      }
      ready = true;
    } catch (_) {
      ready = false; // no audio backend (e.g. tests) — game stays silent
    }
  }

  Future<AudioPlayer> _make(String asset) async {
    final AudioPlayer p = AudioPlayer();
    await p.setReleaseMode(ReleaseMode.stop);
    await p.setPlayerMode(PlayerMode.lowLatency);
    await p.setSource(AssetSource(asset)); // decode/prepare once
    return p;
  }

  void _trigger(AudioPlayer p) {
    p.seek(Duration.zero).then((_) => p.resume()).catchError((_) {});
  }

  void hit() {
    if (!ready || _hit.isEmpty) return;
    _trigger(_hit[_hi]);
    _hi = (_hi + 1) % _hit.length;
  }

  void miss() {
    if (!ready || _miss.isEmpty) return;
    _trigger(_miss[_mi]);
    _mi = (_mi + 1) % _miss.length;
  }

  void dispose() {
    for (final AudioPlayer p in [..._hit, ..._miss]) {
      p.dispose();
    }
    _hit.clear();
    _miss.clear();
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final GameEngine _game;
  late final Ticker _ticker;
  final SoundFx _sfx = SoundFx();
  Duration _prev = Duration.zero;

  int? _lookPointer;
  int? _firePointer;
  Offset _lastLook = Offset.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sfx.init();
    _game = GameEngine(onFinished: widget.onFinished)
      ..scenario = widget.scenario
      ..sensitivity = widget.settings.sensitivity
      ..fov = widget.settings.fov
      ..fireXNorm = widget.settings.fireX
      ..fireYNorm = widget.settings.fireY
      ..fireScale = widget.settings.fireScale
      ..fireOpacity = widget.settings.fireOpacity
      ..onHit = _sfx.hit
      ..onMiss = _sfx.miss;
    _game.stats.scoreScale = kScoreScale[widget.scenario];
    _game.applyTuning(widget.settings.tune);
    _ticker = createTicker(_tick)..start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Auto-pause when the app loses focus (notification, call, app switch)
    // so a round isn't ruined in the background.
    if (state != AppLifecycleState.resumed &&
        _game.running &&
        _game.started &&
        !_game.paused) {
      _setPaused(true);
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _game.dispose();
    _sfx.dispose();
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
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('PAUSED', style: _fgStyle(24, spacing: 8)),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: 240,
                      child: OutlinedButton(
                        style: _buttonStyle(),
                        onPressed: () => _setPaused(false),
                        child: const Text('RESUME'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 240,
                      child: OutlinedButton(
                        style: _buttonStyle(),
                        onPressed: widget.onRestart,
                        child: const Text('RESTART'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 240,
                      child: OutlinedButton(
                        style: _buttonStyle(),
                        onPressed: widget.onQuit,
                        child: const Text('MENU'),
                      ),
                    ),
                  ],
                ),
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

// Room geometry builders (top-level so the engine can rebuild the REACTIVE
// room from its tunable size). zf/zb are the near/far depth planes.
List<List<(double, double, double)>> buildWalls(double w, double zf, double zb) {
  const double f = kRoomFloor, c = kRoomCeil;
  return [
    [(-w, f, zf), (w, f, zf), (w, f, zb), (-w, f, zb)], // floor
    [(-w, c, zf), (w, c, zf), (w, c, zb), (-w, c, zb)], // ceiling
    [(-w, f, zf), (-w, f, zb), (-w, c, zb), (-w, c, zf)], // left wall
    [(w, f, zf), (w, f, zb), (w, c, zb), (w, c, zf)], // right wall
    [(-w, f, zb), (w, f, zb), (w, c, zb), (-w, c, zb)], // target wall
    [(-w, f, zf), (w, f, zf), (w, c, zf), (-w, c, zf)], // behind player
  ];
}

List<(double, double, double, double, double, double)> buildRoom(
    double w, double zf, double zb) {
  const double f = kRoomFloor, c = kRoomCeil;
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

/// Floor-plane grid lines (constant y = floor) across [-w..w] x [zf..zb],
/// at the given spacing. Used as a horizontal reference in REACTIVE.
List<(double, double, double, double, double, double)> buildFloorGrid(
    double w, double zf, double zb, double spacing) {
  const double f = kRoomFloor;
  final lines = <(double, double, double, double, double, double)>[];
  for (double x = -w; x <= w + 1e-6; x += spacing) {
    lines.add((x, f, zf, x, f, zb));
  }
  for (double z = zf; z <= zb + 1e-6; z += spacing) {
    lines.add((-w, f, z, w, f, z));
  }
  return lines;
}

final List<List<(double, double, double)>> _wallsCubes =
    buildWalls(kRoomHalfW, kRoomFront, kRoomBack);
final List<List<(double, double, double)>> _wallsFloat =
    buildWalls(kRoomHalfW, -kFloatHalfD, kFloatHalfD);
final List<(double, double, double, double, double, double)> _roomCubes =
    buildRoom(kRoomHalfW, kRoomFront, kRoomBack);
final List<(double, double, double, double, double, double)> _roomFloat =
    buildRoom(kRoomHalfW, -kFloatHalfD, kFloatHalfD);

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
    _gridPaint
      ..color = settings.arenaAccent.withValues(alpha: 0.14)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
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
    _sphereFill.color = settings.targetColor;
    _pillCore
      ..color = settings.targetColor
      ..strokeCap = StrokeCap.round;
    _pillOutline
      ..color = settings.arenaBg
      ..strokeCap = StrokeCap.round;
    _pauseBar.color = settings.arenaAccent;
    // Precompute the active room's wall geometry and per-corner fog colors.
    // Fog depends only on distance to the eye, and the camera only rotates
    // (which preserves distance) — so corner colors are constant per round.
    _walls = switch (game.scenario) {
      0 => _wallsCubes,
      2 => game.reactiveWalls,
      _ => _wallsFloat,
    };
    _wallCornerColors = [
      for (final List<(double, double, double)> wall in _walls)
        [
          for (final (double x, double y, double z) in wall)
            _fogColorFor(math.sqrt(x * x + y * y + z * z))
        ]
    ];
  }

  late final Color _fogNear;
  late final Color _fogFar;
  late final Color _shadeTop;
  late final Color _shadeBottom;
  late final Color _shadeSide;
  late final List<List<(double, double, double)>> _walls;
  late final List<List<Color>> _wallCornerColors;

  final GameEngine game;
  final AppSettings settings;
  final Paint _fxStroke = Paint();
  final Paint _bgPaint = Paint();
  final Paint _accentFill = Paint();
  final Paint _edgePaint = Paint();
  final Paint _gridPaint = Paint();
  final Paint _cubeFill = Paint();
  final Paint _sphereFill = Paint();
  final Paint _pillCore = Paint();
  final Paint _pillOutline = Paint();
  final Paint _pauseBar = Paint();
  final Paint _cubeEdge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeJoin = StrokeJoin.round;

  // Reused per-frame scratch buffers for the batched wall fill (#2): cleared
  // and refilled each frame so there's no allocation churn beyond Vertices.
  final List<(double, double, double)> _camBuf = [];
  final List<(double, double, double)> _clipPos = [];
  final List<Color> _clipCol = [];
  final List<Offset> _projBuf = [];
  final List<Offset> _wallPts = [];
  final List<Color> _wallCols = [];

  Color _fogColorFor(double d) =>
      Color.lerp(_fogNear, _fogFar, ((d - 2) / 14).clamp(0, 1))!;

  late final _CachedText _scoreText =
      _CachedText(20, color: settings.arenaAccent);
  late final _CachedText _timeText =
      _CachedText(20, color: settings.arenaAccent);
  late final _CachedText _promptText =
      _CachedText(20, color: settings.arenaAccent);
  late final _CachedText _fpsText =
      _CachedText(13, weight: FontWeight.w400, color: settings.arenaAccent);

  /// Fog-shaded room surfaces. Near-plane clipped, then all walls batched into
  /// a single triangle-list draw call. Corner fog colors are precomputed (they
  /// don't change as the camera rotates); only clip-generated vertices, which
  /// appear when a wall straddles the near plane, are colored per frame — using
  /// the exact same formula, so the result is pixel-identical to per-wall fans.
  void _paintWalls(Canvas canvas, Size size) {
    final double cx = size.width / 2, cy = size.height / 2, fo = game.focal;
    _wallPts.clear();
    _wallCols.clear();
    for (int wi = 0; wi < _walls.length; wi++) {
      final List<(double, double, double)> wall = _walls[wi];
      final List<Color> cornerCols = _wallCornerColors[wi];
      final int n = wall.length;
      _camBuf.clear();
      for (final (double x, double y, double z) in wall) {
        _camBuf.add(game.toCamera(x, y, z));
      }
      // Sutherland-Hodgman clip against z = kNearPlane, carrying colors.
      _clipPos.clear();
      _clipCol.clear();
      for (int i = 0; i < n; i++) {
        final (double, double, double) a = _camBuf[i];
        final (double, double, double) b = _camBuf[(i + 1) % n];
        final bool aIn = a.$3 > kNearPlane, bIn = b.$3 > kNearPlane;
        if (aIn) {
          _clipPos.add(a);
          _clipCol.add(cornerCols[i]);
        }
        if (aIn != bIn) {
          final double t = (kNearPlane - a.$3) / (b.$3 - a.$3);
          final double px = a.$1 + (b.$1 - a.$1) * t;
          final double py = a.$2 + (b.$2 - a.$2) * t;
          _clipPos.add((px, py, kNearPlane));
          _clipCol.add(_fogColorFor(
              math.sqrt(px * px + py * py + kNearPlane * kNearPlane)));
        }
      }
      final int m = _clipPos.length;
      if (m < 3) continue;
      _projBuf.clear();
      for (final (double x, double y, double z) in _clipPos) {
        _projBuf.add(Offset(cx + fo * x / z, cy - fo * y / z));
      }
      // Fan -> triangles, appended to the shared batch (preserves draw order).
      for (int i = 1; i < m - 1; i++) {
        _wallPts.add(_projBuf[0]);
        _wallCols.add(_clipCol[0]);
        _wallPts.add(_projBuf[i]);
        _wallCols.add(_clipCol[i]);
        _wallPts.add(_projBuf[i + 1]);
        _wallCols.add(_clipCol[i + 1]);
      }
    }
    if (_wallPts.length >= 3) {
      canvas.drawVertices(
        ui.Vertices(ui.VertexMode.triangles, _wallPts, colors: _wallCols),
        BlendMode.dst,
        _wallPaint,
      );
    }
  }

  static final Paint _wallPaint = Paint();

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

  /// FLOAT 360 target: a single flat-colored disc with a thin dark outline.
  void _paintSphere(Canvas canvas, Size size) {
    final (double px, double py, double pz) =
        game.toCamera(game.sphereX, game.sphereY, game.sphereZ);
    if (pz <= kNearPlane) return;
    final double cx = size.width / 2, cy = size.height / 2;
    final double r = game.focal * game.sphereR / pz;
    final Offset c = Offset(cx + game.focal * px / pz, cy - game.focal * py / pz);
    canvas.drawCircle(c, r, _sphereFill);
    canvas.drawCircle(c, r, _cubeEdge);
  }

  /// REACTIVE target: capsule rendered as a round-capped line — a single
  /// flat body color with a thin dark silhouette outline.
  void _paintPill(Canvas canvas, Size size) {
    final (double x1, double y1, double z1) =
        game.toCamera(game.rpX, game.pillYC + game.pillHalfH, game.rpZ);
    final (double x2, double y2, double z2) =
        game.toCamera(game.rpX, game.pillYC - game.pillHalfH, game.rpZ);
    if (z1 <= kNearPlane || z2 <= kNearPlane) return;
    final double cx = size.width / 2, cy = size.height / 2, fo = game.focal;
    final Offset top = Offset(cx + fo * x1 / z1, cy - fo * y1 / z1);
    final Offset bottom = Offset(cx + fo * x2 / z2, cy - fo * y2 / z2);
    final double r = fo * game.pillR * 2 / (z1 + z2);
    canvas.drawLine(top, bottom, _pillOutline..strokeWidth = 2 * r + 4);
    canvas.drawLine(top, bottom, _pillCore..strokeWidth = 2 * r);
  }

  @override
  void paint(Canvas canvas, Size size) {
    game.arena = size;
    canvas.drawRect(Offset.zero & size, _bgPaint);
    _paintWalls(canvas, size);

    // REACTIVE: a dim floor grid for horizontal reference while strafing.
    if (game.scenario == 2) {
      for (final (double ax, double ay, double az, double bx, double by,
          double bz) in game.reactiveFloor) {
        _worldLine(canvas, size, ax, ay, az, bx, by, bz, _gridPaint);
      }
    }

    // The room edge lines.
    for (final (double ax, double ay, double az, double bx, double by,
        double bz) in (switch (game.scenario) {
      0 => _roomCubes,
      2 => game.reactiveRoom,
      _ => _roomFloat,
    })) {
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
    const double barW = 6, barH = 22;
    final Offset c = r.center;
    canvas.drawRect(
        Rect.fromCenter(
            center: c - const Offset(6.5, 0), width: barW, height: barH),
        _pauseBar);
    canvas.drawRect(
        Rect.fromCenter(
            center: c + const Offset(6.5, 0), width: barW, height: barH),
        _pauseBar);
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
    required this.topRank,
    required this.onPlay,
    required this.onTuning,
    required this.onProfile,
    required this.onRanks,
    required this.onSettings,
  });

  final Rank? topRank;
  final VoidCallback onPlay;
  final VoidCallback onTuning;
  final VoidCallback onProfile;
  final VoidCallback onRanks;
  final VoidCallback onSettings;

  Widget _navButton(String label, VoidCallback onTap) => TextButton(
        onPressed: onTap,
        child: Text(label,
            style: _fgStyle(13, weight: FontWeight.w500, spacing: 4)),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        // Scale the whole menu down uniformly when the screen is too short.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const _Logo(size: 76),
              const SizedBox(height: 16),
              Text('AIM RANKED',
                  style: _fgStyle(34, weight: FontWeight.w800, spacing: 10)),
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RankBadge(rank: topRank, size: 22),
                  const SizedBox(width: 10),
                  Text(topRank?.name ?? 'UNRANKED',
                      style: TextStyle(
                        color: topRank?.color ?? kFg.withValues(alpha: .55),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 4,
                      )),
                ],
              ),
              const SizedBox(height: 26),
              SizedBox(
                width: 240,
                child: OutlinedButton(
                  style: _buttonStyle(),
                  onPressed: onPlay,
                  child: const Text('PLAY'),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _navButton('PROFILE', onProfile),
                  _navButton('RANKS', onRanks),
                  // TUNING hidden for now — re-add this nav button to expose
                  // the bot-tuning screen again (screen + wiring kept intact).
                  // _navButton('TUNING', onTuning),
                  _navButton('SETTINGS', onSettings),
                ],
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Play — scenario browser. Each card shows the mode, its description, and the
// player's best/rank, and starts a round on tap.
// ---------------------------------------------------------------------------
class _PlayScreen extends StatelessWidget {
  const _PlayScreen({
    required this.bests,
    required this.onPick,
    required this.onBack,
  });

  final Map<int, int> bests;
  final ValueChanged<int> onPick;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _settingsHeader('PLAY', onBack),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      for (int i = 0; i < kScenarios.length; i++) _card(i),
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

  Widget _card(int i) {
    final int best = bests[i] ?? 0;
    final Rank? rank = rankFor(best);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 7),
      child: GestureDetector(
        onTap: () => onPick(i),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            border: Border.all(color: kFg.withValues(alpha: .3)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(kScenarios[i], style: _fgStyle(20, spacing: 5)),
                    const SizedBox(height: 6),
                    Text(
                      kScenarioDesc[i],
                      style: TextStyle(
                        color: kFg.withValues(alpha: .7),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        RankBadge(rank: rank, size: 20),
                        const SizedBox(width: 8),
                        Text('BEST $best',
                            style:
                                _fgStyle(12, weight: FontWeight.w400, spacing: 2)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.play_arrow, color: kFg, size: 34),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tuning — live sliders for every bot parameter, grouped by scenario. Dial
// to taste; values persist so you can read them back and bake in a default.
// ---------------------------------------------------------------------------
class _TuningScreen extends StatefulWidget {
  const _TuningScreen({
    required this.settings,
    required this.onChanged,
    required this.onBack,
  });

  final AppSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onBack;

  @override
  State<_TuningScreen> createState() => _TuningScreenState();
}

class _TuningScreenState extends State<_TuningScreen> {
  Widget _paramSlider(TuneParam p) {
    final double v = widget.settings.tv(p.key);
    final String shown =
        (p.max <= 3 ? v.toStringAsFixed(2) : v.toStringAsFixed(1));
    return Column(
      children: [
        _settingsSliderRow(p.label, shown),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: kFg,
            inactiveTrackColor: kFg.withValues(alpha: .2),
            thumbColor: kFg,
            overlayColor: kFg.withValues(alpha: .12),
            trackHeight: 2,
          ),
          child: Slider(
            value: v.clamp(p.min, p.max),
            min: p.min,
            max: p.max,
            onChanged: (nv) {
              setState(() => widget.settings.tune[p.key] = nv);
            },
            onChangeEnd: (_) => widget.onChanged(),
          ),
        ),
      ],
    );
  }

  Widget _group(String title, int scenario) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(title,
              style: TextStyle(
                color: kFg,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 5,
              )),
        ),
        const SizedBox(height: 6),
        for (final TuneParam p in kTuneParams.where((p) => p.scenario == scenario))
          _paramSlider(p),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _settingsHeader('TUNING', widget.onBack),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    children: [
                      _group('FLOAT 360', 1),
                      _group('REACTIVE', 2),
                      const SizedBox(height: 14),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            for (final TuneParam p in kTuneParams) {
                              widget.settings.tune[p.key] = p.def;
                            }
                          });
                          widget.onChanged();
                        },
                        child: Text('RESET TO DEFAULTS',
                            style: _fgStyle(13,
                                weight: FontWeight.w500, spacing: 3)),
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
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              Text('SETTINGS', style: _fgStyle(24, spacing: 8)),
              const SizedBox(height: 22),
              section('CROSSHAIR', onCrosshair),
              section('COLORS', onColors),
              section('HUD', onHud),
              section('GENERAL', onGeneral),
              const SizedBox(height: 6),
              TextButton(
                onPressed: onBack,
                child: Text('BACK',
                    style: _fgStyle(14, weight: FontWeight.w500, spacing: 4)),
              ),
              const SizedBox(height: 16),
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
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
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
// Ranks showcase — the full ladder, badges, and what each tier means. The
// player's current rank (best across scenarios) is highlighted.
// ---------------------------------------------------------------------------
class _RanksScreen extends StatelessWidget {
  const _RanksScreen({required this.current, required this.onBack});

  final Rank? current;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _settingsHeader('RANKS', onBack),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    children: [
                      const SizedBox(height: 4),
                      for (final Rank r in kRanks.reversed) _rankRow(r),
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

  Widget _rankRow(Rank r) {
    final bool isCurrent = r == current;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(
          color: isCurrent ? r.color : kFg.withValues(alpha: .18),
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          RankBadge(rank: r, size: 46),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      r.name,
                      style: TextStyle(
                        color: r.color,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('${r.threshold}+',
                        style: _fgStyle(12, weight: FontWeight.w400)),
                    if (isCurrent) ...[
                      const Spacer(),
                      Text('YOU',
                          style: TextStyle(
                            color: r.color,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 3,
                          )),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  r.blurb,
                  style: TextStyle(
                    color: kFg.withValues(alpha: .75),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
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

/// Aim Ranked mark: a reticle ring with four ticks and a rank chevron at the
/// center — "aim" (reticle) meeting "ranked" (the upward chevron).
class _Logo extends StatelessWidget {
  const _Logo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _LogoPainter());
  }
}

class _LogoPainter extends CustomPainter {
  static final Paint _stroke = Paint()
    ..color = kFg
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  static final Paint _fill = Paint()..color = kFg;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2 - 2;
    // Reticle ring.
    canvas.drawCircle(c, r * 0.82, _stroke);
    // Four ticks, gapped from the ring inward.
    for (final double a in [0, math.pi / 2, math.pi, 3 * math.pi / 2]) {
      final Offset dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * (r * 0.82), c + dir * r, _stroke);
    }
    // Centered rank chevron (points up).
    final double w = r * 0.42, h = r * 0.30;
    final Path chevron = Path()
      ..moveTo(c.dx - w, c.dy + h * 0.6)
      ..lineTo(c.dx, c.dy - h)
      ..lineTo(c.dx + w, c.dy + h * 0.6);
    canvas.drawPath(chevron, _stroke);
    // Small dot beneath, completing the reticle center.
    canvas.drawCircle(c + Offset(0, r * 0.42), r * 0.07, _fill);
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => false;
}
