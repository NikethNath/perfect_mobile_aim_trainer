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
const int kMaxTargets = 3;
const double kGrowTime = 0.25;
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
enum _Screen { menu, settings, hudEdit, playing, results }

const List<String> kScenarios = ['CUBES'];

const List<Color> kBorderColors = [Color(0xFF000000), ...kTargetColors];

class AppSettings {
  Color targetColor = kFg;
  Color crosshairColor = kFg;
  double crosshairDot = 2.2; // center dot radius (px); 0 removes it
  double crosshairLength = 10; // length of the 4 lines (px); 0 removes them
  double crosshairWidth = 2.5; // stroke width of the 4 lines (px)
  double crosshairBorder = 0; // outline thickness (px); 0 removes it
  Color crosshairBorderColor = const Color(0xFF000000);
  double sensitivity = 1.0;

  // HUD layout. Negative coords mean "default position" (bottom-right).
  double fireX = -1; // normalized 0..1 center of the FIRE button
  double fireY = -1;
  double fireScale = 1.0;
  double fireOpacity = 1.0;

  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    targetColor = Color(prefs.getInt('target_color') ?? kFg.toARGB32());
    crosshairColor = Color(prefs.getInt('crosshair_color') ?? kFg.toARGB32());
    crosshairDot = prefs.getDouble('crosshair_dot') ?? 2.2;
    crosshairLength = prefs.getDouble('crosshair_length') ?? 10;
    crosshairWidth = prefs.getDouble('crosshair_width') ?? 2.5;
    crosshairBorder = prefs.getDouble('crosshair_border') ?? 0;
    crosshairBorderColor =
        Color(prefs.getInt('crosshair_border_color') ?? 0xFF000000);
    sensitivity = prefs.getDouble('sensitivity') ?? 1.0;
    fireX = prefs.getDouble('fire_x') ?? -1;
    fireY = prefs.getDouble('fire_y') ?? -1;
    fireScale = prefs.getDouble('fire_scale') ?? 1.0;
    fireOpacity = prefs.getDouble('fire_opacity') ?? 1.0;
  }

  Future<void> save() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('target_color', targetColor.toARGB32());
    await prefs.setInt('crosshair_color', crosshairColor.toARGB32());
    await prefs.setDouble('crosshair_dot', crosshairDot);
    await prefs.setDouble('crosshair_length', crosshairLength);
    await prefs.setDouble('crosshair_width', crosshairWidth);
    await prefs.setDouble('crosshair_border', crosshairBorder);
    await prefs.setInt(
        'crosshair_border_color', crosshairBorderColor.toARGB32());
    await prefs.setDouble('sensitivity', sensitivity);
    await prefs.setDouble('fire_x', fireX);
    await prefs.setDouble('fire_y', fireY);
    await prefs.setDouble('fire_scale', fireScale);
    await prefs.setDouble('fire_opacity', fireOpacity);
  }
}

/// Shared crosshair renderer used by the game HUD and the settings preview.
/// Border is drawn first as a fatter pass underneath the main color.
void drawCrosshair(Canvas canvas, Offset center, AppSettings s) {
  const double gap = 6;
  final double thick = s.crosshairWidth;
  final double len = s.crosshairLength;
  final double dotR = s.crosshairDot;
  final double bw = s.crosshairBorder;

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

  final AppSettings _settings = AppSettings();
  _Screen _screen = _Screen.menu;
  RoundStats? _last;
  int _best = 0;
  int _scenario = 0;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() => _best = prefs.getInt(_bestKey) ?? 0);
    });
    _settings.load().then((_) {
      if (mounted) setState(() {});
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
            settings: _settings,
            onChanged: () {
              setState(() {});
              _settings.save();
            },
            onHud: () => setState(() => _screen = _Screen.hudEdit),
            onBack: () => setState(() => _screen = _Screen.menu),
          ),
        _Screen.hudEdit => _HudEditScreen(
            settings: _settings,
            onChanged: () {
              setState(() {});
              _settings.save();
            },
            onBack: () => setState(() => _screen = _Screen.settings),
          ),
        _Screen.playing => GameScreen(
            settings: _settings,
            onFinished: _onRoundFinished,
            onQuit: () => setState(() => _screen = _Screen.menu),
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
  bool paused = false;
  Size arena = Size.zero;

  // HUD layout, copied from AppSettings at round start.
  double fireXNorm = -1;
  double fireYNorm = -1;
  double fireScale = 1.0;
  double fireOpacity = 1.0;

  // First-person camera at the origin, starting square at the target wall.
  double yaw = 0;
  double pitch = 0;
  double sensitivity = 1.0;

  // Transient feedback timers (seconds remaining).
  double flashT = 0; // muzzle ring after any shot
  double hitT = 0; // hit marker after a kill
  bool firePressed = false;

  double get timeLeft =>
      (kRoundSeconds - clock).clamp(0, kRoundSeconds).toDouble();

  double get focal => arena.shortestSide * 1.1;

  // Fire button geometry (player-adjustable via Customise HUD).
  double get fireR =>
      (arena.shortestSide * 0.115 * fireScale).clamp(28.0, 90.0);
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
    if (flashT > 0) flashT -= dt;
    if (hitT > 0) hitT -= dt;
    if (countdown > 0) {
      countdown -= dt;
      notifyListeners();
      return;
    }
    clock += dt;
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

  /// Quick grow-in on spawn; targets then live until shot.
  double halfOf(TargetCube t) {
    final double age = clock - t.born;
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
    if (!running || paused || countdown > 0) return;
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
  const GameScreen({
    super.key,
    required this.settings,
    required this.onFinished,
    required this.onQuit,
  });

  final AppSettings settings;
  final void Function(RoundStats) onFinished;
  final VoidCallback onQuit;

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
      ..sensitivity = widget.settings.sensitivity
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
  _GamePainter(this.game, this.settings) : super(repaint: game) {
    _cubeFill.color = settings.targetColor;
    _fxStroke
      ..color = settings.crosshairColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
  }

  final GameEngine game;
  final AppSettings settings;
  final Paint _fxStroke = Paint();

  static final Paint _bgPaint = Paint()..color = kBg;
  static final Paint _fgFill = Paint()..color = kFg;
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
      _paintPauseButton(canvas);
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

    // Crosshair per player settings.
    final Offset center = Offset(cx, cy);
    drawCrosshair(canvas, center, settings);

    // Muzzle ring after a shot; X-shaped hit marker after a kill.
    if (game.flashT > 0) {
      final double k = 1 - game.flashT / 0.12;
      canvas.drawCircle(center, 14 + k * 12, _fxStroke);
    }
    if (game.hitT > 0) {
      for (final (double dx, double dy) in [
        (1.0, 1.0),
        (-1.0, 1.0),
        (1.0, -1.0),
        (-1.0, -1.0)
      ]) {
        final Offset dir = Offset(dx, dy) / math.sqrt2;
        canvas.drawLine(center + dir * 9, center + dir * 19, _fxStroke);
      }
    }

    // HUD: time bar, score top-left, clock top-center, pause top-right.
    final double frac = game.timeLeft / kRoundSeconds;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * frac, 4), _fgFill);
    final TextPainter score = _scoreText.of('${game.stats.score}');
    score.paint(canvas, const Offset(20, 18));
    final TextPainter time = _timeText.of(game.timeLeft.ceil().toString());
    time.paint(canvas, Offset((size.width - time.width) / 2, 18));

    _paintPauseButton(canvas);
    _paintFireButton(canvas);
  }

  void _paintPauseButton(Canvas canvas) {
    final Rect r = game.pauseRect;
    final Paint bar = Paint()..color = kFg;
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
    final Offset c = game.fireCenter;
    final double r = game.fireR;
    final double op = game.fireOpacity.clamp(0.15, 1.0);
    final Paint ring = Paint()
      ..color = kFg.withValues(alpha: op)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final Paint fill = Paint()..color = kFg.withValues(alpha: op);
    canvas.drawCircle(c, r, ring);
    canvas.drawCircle(c, r * (game.firePressed ? 0.82 : 0.30), fill);
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
    required this.settings,
    required this.onChanged,
    required this.onHud,
    required this.onBack,
  });

  final AppSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onHud;
  final VoidCallback onBack;

  Widget _label(String s) =>
      Text(s, style: _fgStyle(13, weight: FontWeight.w400, spacing: 4));

  Widget _swatches(Color selected, ValueChanged<Color> pick,
      {List<Color> palette = kTargetColors}) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        for (final Color c in palette)
          GestureDetector(
            onTap: () => pick(c),
            child: Container(
              width: 38,
              height: 38,
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
    );
  }

  Widget _slider(
      double value, double min, double max, ValueChanged<double> set) {
    return SliderTheme(
      data: SliderThemeData(
        activeTrackColor: kFg,
        inactiveTrackColor: kFg.withValues(alpha: .2),
        thumbColor: kFg,
        overlayColor: kFg.withValues(alpha: .12),
        trackHeight: 2,
      ),
      child: Slider(value: value, min: min, max: max, onChanged: set),
    );
  }

  Widget _sliderRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [_label(label), Text(value, style: _fgStyle(13))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              children: [
                const SizedBox(height: 28),
                Text('SETTINGS', style: _fgStyle(24, spacing: 8)),
                const SizedBox(height: 20),
                // Live crosshair preview.
                Container(
                  width: 200,
                  height: 76,
                  decoration: BoxDecoration(
                    border: Border.all(color: kFg.withValues(alpha: .25)),
                  ),
                  child: CustomPaint(
                    painter: _CrosshairPreviewPainter(
                      settings.crosshairColor,
                      settings.crosshairDot,
                      settings.crosshairLength,
                      settings.crosshairWidth,
                      settings.crosshairBorder,
                      settings.crosshairBorderColor,
                      settings,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _label('TARGET COLOR'),
                const SizedBox(height: 10),
                _swatches(settings.targetColor, (c) {
                  settings.targetColor = c;
                  onChanged();
                }),
                const SizedBox(height: 24),
                _label('CROSSHAIR COLOR'),
                const SizedBox(height: 10),
                _swatches(settings.crosshairColor, (c) {
                  settings.crosshairColor = c;
                  onChanged();
                }),
                const SizedBox(height: 24),
                _label('CROSSHAIR BORDER COLOR'),
                const SizedBox(height: 10),
                _swatches(settings.crosshairBorderColor, (c) {
                  settings.crosshairBorderColor = c;
                  onChanged();
                }, palette: kBorderColors),
                const SizedBox(height: 24),
                _sliderRow(
                    'CENTER DOT SIZE', settings.crosshairDot.toStringAsFixed(1)),
                _slider(settings.crosshairDot, 0, 8, (v) {
                  settings.crosshairDot = v;
                  onChanged();
                }),
                const SizedBox(height: 12),
                _sliderRow('CROSSHAIR LENGTH',
                    settings.crosshairLength.toStringAsFixed(0)),
                _slider(settings.crosshairLength, 0, 30, (v) {
                  settings.crosshairLength = v;
                  onChanged();
                }),
                const SizedBox(height: 12),
                _sliderRow('CROSSHAIR WIDTH',
                    settings.crosshairWidth.toStringAsFixed(1)),
                _slider(settings.crosshairWidth, 1, 8, (v) {
                  settings.crosshairWidth = v;
                  onChanged();
                }),
                const SizedBox(height: 12),
                _sliderRow('BORDER THICKNESS',
                    settings.crosshairBorder.toStringAsFixed(1)),
                _slider(settings.crosshairBorder, 0, 4, (v) {
                  settings.crosshairBorder = v;
                  onChanged();
                }),
                const SizedBox(height: 12),
                _sliderRow('SENSITIVITY',
                    '${settings.sensitivity.toStringAsFixed(1)}X'),
                _slider(settings.sensitivity, 0.4, 2.4, (v) {
                  settings.sensitivity = v;
                  onChanged();
                }),
                const SizedBox(height: 28),
                OutlinedButton(
                  style: _buttonStyle(),
                  onPressed: onHud,
                  child: const Text('CUSTOMISE HUD'),
                ),
                const SizedBox(height: 20),
                OutlinedButton(
                  style: _buttonStyle(),
                  onPressed: onBack,
                  child: const Text('BACK'),
                ),
                const SizedBox(height: 28),
              ],
            ),
          ),
        ),
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
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: kFg,
                inactiveTrackColor: kFg.withValues(alpha: .2),
                thumbColor: kFg,
                overlayColor: kFg.withValues(alpha: .12),
                trackHeight: 2,
              ),
              child: Slider(
                value: v,
                min: min,
                max: max,
                onChanged: (nv) {
                  set(nv);
                  setState(() {});
                },
                onChangeEnd: (_) => widget.onChanged(),
              ),
            ),
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
        (size.shortestSide * 0.115 * s.fireScale).clamp(28.0, 90.0);
    final Offset c = (s.fireX < 0 || s.fireY < 0)
        ? Offset(size.width - r - 26, size.height - r - 30)
        : Offset(
            (s.fireX * size.width).clamp(r, size.width - r),
            (s.fireY * size.height).clamp(r, size.height - r),
          );
    final double op = s.fireOpacity.clamp(0.15, 1.0);

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
            onPanUpdate: (d) {
              setState(() {
                s.fireX = ((c.dx + d.delta.dx) / size.width).clamp(0.0, 1.0);
                s.fireY = ((c.dy + d.delta.dy) / size.height).clamp(0.0, 1.0);
              });
            },
            onPanEnd: (_) => widget.onChanged(),
            child: Container(
              width: r * 2,
              height: r * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: kFg.withValues(alpha: op), width: 2.5),
              ),
              child: Center(
                child: Container(
                  width: r * 0.6,
                  height: r * 0.6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kFg.withValues(alpha: op),
                  ),
                ),
              ),
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
                  s.fireOpacity, 0.15, 1.0, (v) => s.fireOpacity = v),
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

class _CrosshairPreviewPainter extends CustomPainter {
  // The value fields exist only so shouldRepaint can detect changes to the
  // (mutable, shared) settings object between frames.
  _CrosshairPreviewPainter(this.color, this.dot, this.length, this.width,
      this.border, this.borderColor, this.settings);

  final Color color;
  final double dot;
  final double length;
  final double width;
  final double border;
  final Color borderColor;
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
      oldDelegate.borderColor != borderColor;
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
