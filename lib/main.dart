import 'dart:math' as math;

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
const double kRoundSeconds = 30;
const int kMaxTargets = 2;
const double kTargetLife = 3.5; // seconds from spawn to expiry
const double kGrowTime = 0.25;
const double kShrinkTime = 1.2;
const int kHitScore = 100;
const int kMissPenalty = 25;

// 3D tuning.
const double kCubeHalf = 0.5; // target cube half-extent (world units)
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
enum _Screen { menu, settings, playing, results }

const List<String> kScenarios = ['CUBES'];

class RoundStats {
  int hits = 0;
  int misses = 0;
  int score = 0;
  double sumKillMs = 0;

  double get accuracy => hits + misses == 0 ? 0 : hits / (hits + misses);
  double get avgKillMs => hits == 0 ? 0 : sumKillMs / hits;
}

class HomeFlow extends StatefulWidget {
  const HomeFlow({super.key});

  @override
  State<HomeFlow> createState() => _HomeFlowState();
}

class _HomeFlowState extends State<HomeFlow> {
  static const String _bestKey = 'best_score';
  static const String _colorKey = 'target_color';

  _Screen _screen = _Screen.menu;
  RoundStats? _last;
  int _best = 0;
  int _scenario = 0;
  Color _targetColor = kFg;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _best = prefs.getInt(_bestKey) ?? 0;
        _targetColor = Color(prefs.getInt(_colorKey) ?? kFg.toARGB32());
      });
    });
  }

  void _onRoundFinished(RoundStats stats) {
    if (stats.score > _best) {
      _best = stats.score;
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setInt(_bestKey, _best));
    }
    setState(() {
      _last = stats;
      _screen = _Screen.results;
    });
  }

  void _pickColor(Color c) {
    setState(() => _targetColor = c);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt(_colorKey, c.toARGB32()));
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
            onSettings: () => setState(() => _screen = _Screen.settings),
          ),
        _Screen.settings => _SettingsScreen(
            selected: _targetColor,
            onPick: _pickColor,
            onBack: () => setState(() => _screen = _Screen.menu),
          ),
        _Screen.playing => GameScreen(
            targetColor: _targetColor,
            onFinished: _onRoundFinished,
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
  double clock = 0; // seconds since countdown ended
  double countdown = 3;
  bool running = true;
  Size arena = Size.zero;

  // First-person camera at the origin, starting square at the target wall.
  double yaw = 0;
  double pitch = 0;

  // Transient feedback timers (seconds remaining).
  double flashT = 0; // muzzle ring after any shot
  double hitT = 0; // hit marker after a kill
  bool firePressed = false;

  double get timeLeft =>
      (kRoundSeconds - clock).clamp(0, kRoundSeconds).toDouble();

  double get focal => arena.shortestSide * 1.1;

  // Fire button geometry (bottom-right HUD).
  double get fireR => (arena.shortestSide * 0.115).clamp(40.0, 60.0);
  Offset get fireCenter =>
      Offset(arena.width - fireR - 26, arena.height - fireR - 30);
  bool inFireButton(Offset p) => (p - fireCenter).distance <= fireR * 1.25;

  void look(Offset delta) {
    if (!running) return;
    yaw += delta.dx * kLookSens;
    pitch = (pitch - delta.dy * kLookSens).clamp(-kPitchLimit, kPitchLimit);
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
    if (!running) return;
    if (flashT > 0) flashT -= dt;
    if (hitT > 0) hitT -= dt;
    if (countdown > 0) {
      countdown -= dt;
      notifyListeners();
      return;
    }
    clock += dt;
    targets.removeWhere((t) {
      if (clock - t.born > kTargetLife) {
        stats.misses++;
        return true;
      }
      return false;
    });
    if (arena != Size.zero) {
      while (targets.length < kMaxTargets) {
        targets.add(_spawn());
      }
    }
    if (clock >= kRoundSeconds) {
      running = false;
      onFinished(stats);
    }
    notifyListeners();
  }

  /// Grow-in / shrink-out lifetime profile applied to the cube half-extent.
  double halfOf(TargetCube t) {
    final double age = clock - t.born;
    final double grow =
        Curves.easeOutBack.transform((age / kGrowTime).clamp(0.0, 1.0));
    final double shrink = ((kTargetLife - age) / kShrinkTime).clamp(0.0, 1.0);
    return kCubeHalf * grow * shrink;
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
    if (!running || countdown > 0) return;
    flashT = 0.12;
    HapticFeedback.selectionClick();
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
      stats.score += kHitScore;
      hitT = 0.18;
      HapticFeedback.lightImpact();
      targets.add(_spawn());
    } else {
      stats.misses++;
      stats.score = math.max(0, stats.score - kMissPenalty);
    }
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Game screen — raw pointer routing: one finger swipes to aim while another
// presses FIRE. Listener avoids the gesture-arena delay entirely.
// ---------------------------------------------------------------------------
class GameScreen extends StatefulWidget {
  const GameScreen(
      {super.key, required this.targetColor, required this.onFinished});

  final Color targetColor;
  final void Function(RoundStats) onFinished;

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
    _game = GameEngine(onFinished: widget.onFinished);
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final double dt =
        (elapsed - _prev).inMicroseconds / Duration.microsecondsPerSecond;
    _prev = elapsed;
    // Clamp dt so a dropped frame or app pause can't teleport the clock.
    _game.update(dt.clamp(0.0, 1 / 15));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _game.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent e) {
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
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _up(e.pointer),
      onPointerCancel: (e) => _up(e.pointer),
      child: CustomPaint(
        painter: _GamePainter(_game, widget.targetColor),
        size: Size.infinite,
        willChange: true,
      ),
    );
  }
}

/// TextPainter that only re-lays-out when its string changes.
class _CachedText {
  _CachedText(this.fontSize, {this.weight = FontWeight.w600});

  final double fontSize;
  final FontWeight weight;
  String? _last;
  TextPainter? _tp;

  TextPainter of(String s) {
    if (s != _last) {
      _tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            color: kFg,
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
  _GamePainter(this.game, Color targetColor) : super(repaint: game) {
    _cubeFill.color = targetColor;
  }

  final GameEngine game;

  static final Paint _bgPaint = Paint()..color = kBg;
  static final Paint _fgFill = Paint()..color = kFg;
  static final Paint _fgStroke = Paint()
    ..color = kFg
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;
  static final Paint _gridPaint = Paint()
    ..color = kFg.withValues(alpha: 0.13)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  static final Paint _edgePaint = Paint()
    ..color = kFg.withValues(alpha: 0.35)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final Paint _cubeFill = Paint();
  static final Paint _cubeEdge = Paint()
    ..color = kBg
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeJoin = StrokeJoin.round;

  final _CachedText _scoreText = _CachedText(20);
  final _CachedText _timeText = _CachedText(20);
  final _CachedText _countText = _CachedText(96, weight: FontWeight.w800);

  // The room as world-space line segments: 12 cube edges plus grids on the
  // floor and the target wall. Built once.
  static final List<(double, double, double, double, double, double, bool)>
      _room = _buildRoom();

  static List<(double, double, double, double, double, double, bool)>
      _buildRoom() {
    const double w = kRoomHalfW,
        f = kRoomFloor,
        c = kRoomCeil,
        zf = kRoomFront,
        zb = kRoomBack;
    final lines = <(double, double, double, double, double, double, bool)>[];
    // 12 edges of the room cube (drawn brighter).
    for (final (double y1, double y2) in [(f, f), (c, c)]) {
      lines.add((-w, y1, zf, w, y2, zf, true));
      lines.add((-w, y1, zb, w, y2, zb, true));
      lines.add((-w, y1, zf, -w, y2, zb, true));
      lines.add((w, y1, zf, w, y2, zb, true));
    }
    for (final double x in [-w, w]) {
      lines.add((x, f, zf, x, c, zf, true));
      lines.add((x, f, zb, x, c, zb, true));
    }
    // Floor grid.
    for (double x = -w + 2; x <= w - 2 + 1e-9; x += 2) {
      lines.add((x, f, zf, x, f, zb, false));
    }
    for (double z = zf + 3; z < zb; z += 3) {
      lines.add((-w, f, z, w, f, z, false));
    }
    // Target-wall grid.
    for (double x = -w + 2; x <= w - 2 + 1e-9; x += 2) {
      lines.add((x, f, zb, x, c, zb, false));
    }
    for (double y = f + 2; y < c; y += 2) {
      lines.add((-w, y, zb, w, y, zb, false));
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
      final Path face = Path()
        ..moveTo(pts[a].dx, pts[a].dy)
        ..lineTo(pts[b].dx, pts[b].dy)
        ..lineTo(pts[c].dx, pts[c].dy)
        ..lineTo(pts[d].dx, pts[d].dy)
        ..close();
      canvas.drawPath(face, _cubeFill);
      canvas.drawPath(face, _cubeEdge);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    game.arena = size;
    canvas.drawRect(Offset.zero & size, _bgPaint);

    // The room: grids dim, cube-room edges brighter.
    for (final (double ax, double ay, double az, double bx, double by,
        double bz, bool edge) in _room) {
      _worldLine(canvas, size, ax, ay, az, bx, by, bz,
          edge ? _edgePaint : _gridPaint);
    }

    final double cx = size.width / 2, cy = size.height / 2;

    if (game.countdown > 0) {
      final TextPainter tp = _countText.of('${game.countdown.ceil()}');
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
      _paintFireButton(canvas);
      return;
    }

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

    // Crosshair: center dot + four ticks with a gap.
    final Offset center = Offset(cx, cy);
    canvas.drawCircle(center, 2.2, _fgFill);
    for (final (double dx, double dy) in [
      (1.0, 0.0),
      (-1.0, 0.0),
      (0.0, 1.0),
      (0.0, -1.0)
    ]) {
      final Offset dir = Offset(dx, dy);
      canvas.drawLine(center + dir * 7, center + dir * 17, _fgStroke);
    }

    // Muzzle ring after a shot; X-shaped hit marker after a kill.
    if (game.flashT > 0) {
      final double k = 1 - game.flashT / 0.12;
      canvas.drawCircle(center, 14 + k * 12, _fgStroke);
    }
    if (game.hitT > 0) {
      for (final (double dx, double dy) in [
        (1.0, 1.0),
        (-1.0, 1.0),
        (1.0, -1.0),
        (-1.0, -1.0)
      ]) {
        final Offset dir = Offset(dx, dy) / math.sqrt2;
        canvas.drawLine(center + dir * 9, center + dir * 19, _fgStroke);
      }
    }

    // HUD: time bar, score, countdown clock.
    final double frac = game.timeLeft / kRoundSeconds;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * frac, 4), _fgFill);
    final TextPainter score = _scoreText.of('${game.stats.score}');
    score.paint(canvas, const Offset(20, 18));
    final TextPainter time = _timeText.of(game.timeLeft.ceil().toString());
    time.paint(canvas, Offset(size.width - time.width - 20, 18));

    _paintFireButton(canvas);
  }

  void _paintFireButton(Canvas canvas) {
    final Offset c = game.fireCenter;
    final double r = game.fireR;
    canvas.drawCircle(c, r, _fgStroke);
    if (game.firePressed) {
      canvas.drawCircle(c, r * 0.82, _fgFill);
    } else {
      canvas.drawCircle(c, r * 0.30, _fgFill);
    }
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
    required this.onSettings,
  });

  final int best;
  final int scenario;
  final ValueChanged<int> onScenario;
  final VoidCallback onStart;
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
          Text('BEST  $best', style: _fgStyle(16)),
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
          TextButton(
            onPressed: onSettings,
            child: Text('SETTINGS',
                style: _fgStyle(13, weight: FontWeight.w500, spacing: 4)),
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
    required this.selected,
    required this.onPick,
    required this.onBack,
  });

  final Color selected;
  final ValueChanged<Color> onPick;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('SETTINGS', style: _fgStyle(24, spacing: 8)),
          const SizedBox(height: 40),
          Text('TARGET COLOR',
              style: _fgStyle(14, weight: FontWeight.w400, spacing: 4)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final Color c in kTargetColors)
                GestureDetector(
                  onTap: () => onPick(c),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: c,
                      border: Border.all(
                        color: c == selected ? kFg : kFg.withValues(alpha: .25),
                        width: c == selected ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 48),
          OutlinedButton(
            style: _buttonStyle(),
            onPressed: onBack,
            child: const Text('BACK'),
          ),
        ],
      ),
    );
  }
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(isBest ? 'NEW BEST' : 'ROUND OVER',
              style: _fgStyle(20, spacing: 6)),
          const SizedBox(height: 8),
          Text('${stats.score}', style: _fgStyle(72, weight: FontWeight.w800)),
          const SizedBox(height: 32),
          _statRow('HITS', '${stats.hits}'),
          _statRow('MISSES', '${stats.misses}'),
          _statRow('ACCURACY', '${(stats.accuracy * 100).toStringAsFixed(0)}%'),
          _statRow('AVG KILL', '${stats.avgKillMs.toStringAsFixed(0)} MS'),
          const SizedBox(height: 40),
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
        ],
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
