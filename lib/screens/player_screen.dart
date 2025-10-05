import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/playback_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  // ---------- vitesse ----------
  double _speed = 1.0;
  static const List<double> _speedPresets = [0.50, 0.75, 1.00, 1.25, 1.50];


// ---------- FENÊTRE DE VUE (ZOOM SUR LA TIMELINE) ----------
  double? _viewStartMs; // null => vue complète
  double? _viewEndMs;   // null => vue complète

  bool get _hasDuration => _duration != Duration.zero;
  double get _durMs => _duration.inMilliseconds.toDouble();
  double get _posMs => _position.inMilliseconds.toDouble();
  bool get _isZoomed => _hasDuration && _viewStartMs != null && _viewEndMs != null && _viewEndMs! > _viewStartMs!;

  void _setViewWindow(double startMs, double endMs) {
    if (!_hasDuration) return;
    const minLen = 400.0; // fenêtre min ~0.4s
    startMs = startMs.clamp(0.0, _durMs);
    endMs   = endMs.clamp(0.0, _durMs);
    if (endMs - startMs < minLen) {
      final mid = (startMs + endMs) / 2;
      startMs = (mid - minLen / 2).clamp(0.0, _durMs - minLen);
      endMs   = startMs + minLen;
    }
    setState(() { _viewStartMs = startMs; _viewEndMs = endMs; });
  }

  void _zoomReset() {
    setState(() { _viewStartMs = null; _viewEndMs = null; });
  }

  /// Zoome sur la boucle A↔B avec un peu de marge (25%)
  void _zoomToLoop() {
    if (_a == null || _b == null || _a! >= _b! || !_hasDuration) return;
    final a = _a!.inMilliseconds.toDouble();
    final b = _b!.inMilliseconds.toDouble();
    final len = (b - a).clamp(400.0, _durMs);
    final pad = len * 0.25; // 25% de marge de chaque côté
    _setViewWindow((a - pad), (b + pad));
  }
  // ---------- média ----------
  String? _mediaPath;
  VideoPlayerController? _video;
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub; // durationStream (audio)
  StreamSubscription? _loopSub;

  bool get _isVideo => _video != null;
  bool get _isPlaying => _isVideo ? _video!.value.isPlaying : _audio.playing;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  // après un seek manuel, on évite de recoller sur A au tick suivant
  bool _skipLoopOnce = false;

  // ---------- A/B & boucle ----------
  Duration? _a;
  Duration? _b;
  bool _loopEnabled = false;
  int _quickGapMs = 4000; // paramétrable : 2/4/8/16s
  static const _kPrefGap = 'quick.gap.ms';

  // ---------- prefs (partagées) ----------
  SharedPreferences? _prefs;
  static const _kPrefPath = 'last.media';
  static const _kPrefSpeed = 'last.speed';
  static const _kPrefA = 'last.a';
  static const _kPrefB = 'last.b';
  static const _kPrefLoop = 'last.loop';

  // ---------- boucles persistées (JSON) ----------
  static const _kPrefLoops = 'loops.json';
  static const _kPrefActiveLoop = 'last.activeLoopIndex';
  static const List<int> _loopPalette = [
    0xFFEF4444, // rouge
    0xFF22D3EE, // cyan
    0xFFF59E0B, // orange
    0xFFA78BFA, // violet
    0xFF34D399, // vert
  ];
  final List<_SavedLoop> _loops = <_SavedLoop>[];
  int _activeLoopIndex = -1;

  // ---------- HUD ----------
  bool _hudVisible = false;
  Timer? _hudHideTimer;
  void _showHud() {
    _hudHideTimer?.cancel();
    setState(() => _hudVisible = true);
    _hudHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  // ---------- lifecycle ----------
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();

    // Abonnement : boucles envoyées par l’Editor via PlaybackService
    PlaybackService.I.subscribeLoop((a, b, enabled) {
      if (!mounted) return;
      setState(() {
        _a = a;
        _b = b;
        _loopEnabled = enabled && a < b;
      });
      _skipLoopOnce = true;
      _seek(a);
      _save();
    });
  }

  @override
  void dispose() {
    _loopSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _save();
  }

  @override
  bool get wantKeepAlive => true;

  // =========================================================
  //                  CHARGEMENT / SAUVEGARDE
  // =========================================================

  Future<void> _restore() async {
    _prefs ??= await SharedPreferences.getInstance();
    final path = _prefs!.getString(_kPrefPath);
    _speed = _prefs!.getDouble(_kPrefSpeed) ?? 1.0;
    _loopEnabled = _prefs!.getBool(_kPrefLoop) ?? false;
    _quickGapMs = _prefs!.getInt(_kPrefGap) ?? 4000;

    final aMs = _prefs!.getInt(_kPrefA);
    final bMs = _prefs!.getInt(_kPrefB);
    _a = (aMs != null && aMs >= 0) ? Duration(milliseconds: aMs) : null;
    _b = (bMs != null && bMs >= 0) ? Duration(milliseconds: bMs) : null;

    _loadLoopsFromPrefs();

    if (path != null && File(path).existsSync()) {
      await _openPath(path, autostart: false);
    } else {
      // reset de la fenêtre de vue à l’ouverture
      _viewStartMs = null;
      _viewEndMs = null;setState(() {}); // peindre l’écran vide
    }
  }

  void _loadLoopsFromPrefs() {
    _loops.clear();
    final raw = _prefs!.getString(_kPrefLoops);
    if (raw != null && raw.isNotEmpty) {
      final List data = json.decode(raw) as List;
      _loops.addAll(data.map((e) => _SavedLoop.fromJson(e as Map<String, dynamic>)));
    }
    _activeLoopIndex = _prefs!.getInt(_kPrefActiveLoop) ?? -1;
  }

  Future<void> _saveLoopsToPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    final jsonStr = json.encode(_loops.map((e) => e.toJson()).toList());
    await _prefs!.setString(_kPrefLoops, jsonStr);
    await _prefs!.setInt(_kPrefActiveLoop, _activeLoopIndex);
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (_mediaPath != null) _prefs!.setString(_kPrefPath, _mediaPath!);
    _prefs!.setDouble(_kPrefSpeed, _speed);
    _prefs!.setBool(_kPrefLoop, _loopEnabled);
    _prefs!.setInt(_kPrefA, _a?.inMilliseconds ?? -1);
    _prefs!.setInt(_kPrefB, _b?.inMilliseconds ?? -1);
    _prefs!.setInt(_kPrefGap, _quickGapMs);
    await _saveLoopsToPrefs();
  }

  // =========================================================
  //                         MEDIA
  // =========================================================

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'mov', 'm4v', 'mp3', 'wav', 'aac', 'm4a'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    await _openPath(path);
  }

  Future<void> _openPath(String path, {bool autostart = true}) async {
    // stop & clean locaux
    _posSub?.cancel();
    await _audio.stop();
    await _video?.pause();
    await _video?.dispose();
    _video = null;

    _mediaPath = path;
    final ext = p.extension(path).toLowerCase();

    if (<String>{'.mp4', '.mov', '.m4v'}.contains(ext)) {
      // ---------- VIDEO ----------
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      _video = c;
      _duration = c.value.duration;
      _position = Duration.zero;

      // informer le service
      PlaybackService.I.attach(video: _video);
      PlaybackService.I.updateDuration(_duration);

      _posSub = Stream<Duration>.periodic(const Duration(milliseconds: 200), (_) {
        return _video?.value.position ?? Duration.zero;
      }).listen(_onTick);

      await c.setPlaybackSpeed(_speed);
      if (autostart) await c.play();
    } else {
      // ---------- AUDIO ----------
      await _audio.setFilePath(path);
      await _audio.setSpeed(_speed);
      _duration = _audio.duration ?? Duration.zero;
      _position = Duration.zero;

      PlaybackService.I.attach(audio: _audio);
      PlaybackService.I.updateDuration(_duration);

      _posSub = _audio.positionStream.listen(_onTick);

      // maj durée si elle arrive après
      _durSub = _audio.durationStream.listen((d) {
        if (d != null) {
          _duration = d;
          PlaybackService.I.updateDuration(d);
          if (mounted) setState(() {});
        }
      });

      if (autostart) await _audio.play();
    }

    // sécuriser A/B dans la nouvelle durée
    if (_duration == Duration.zero) {
      _a = null; _b = null; _loopEnabled = false;
    } else {
      if (_a != null) _a = _clampDur(_a!, Duration.zero, _duration);
      if (_b != null) _b = _clampDur(_b!, Duration.zero, _duration);
      if (_a != null && _b != null && !(_a! < _b!)) _loopEnabled = false;
    }

    setState(() {});
    _save();
  }

  // tick : applique la logique de boucle
  void _onTick(Duration pos) {
    if (!mounted) return;
    if (_duration == Duration.zero) return;

    // notifie le service en premier
    PlaybackService.I.updatePosition(pos);

    // si on vient de seek, on ne recolle pas sur A au tick suivant
    if (_skipLoopOnce) {
      _skipLoopOnce = false;
      setState(() => _position = pos);
      return;
    }

    // boucle A/B
    if (_loopEnabled && _a != null && _b != null && _a! < _b!) {
      if (pos >= _b!) {
        _seek(_a!);
        return;
      }
    }
    setState(() => _position = pos);
  }

  Future<void> _playPause() async {
    if (_mediaPath == null) {
      await _pickFile();
      return;
    }
    if (_isVideo) {
      if (_video!.value.isPlaying) {
        await _video!.pause();
      } else {
        await _video!.play();
      }
    } else {
      if (_audio.playing) {
        await _audio.pause();
      } else {
        await _audio.play();
      }
    }
  }

  Future<void> _seek(Duration d) async {
    d = _clampDur(d, Duration.zero, _duration);
    if (_isVideo) {
      await _video!.seekTo(d);
    } else {
      await _audio.seek(d);
    }
    setState(() => _position = d);
    // push immédiat au service
    PlaybackService.I.updatePosition(d);
  }

  Future<void> _seekBy(Duration delta) async {
    final target = _clampDur(_position + delta, Duration.zero, _duration);
    _skipLoopOnce = true; // ne pas recoller sur A immédiatement
    await _seek(target);
  }
  void _nudgeA(int deltaMs) {
    if (_duration == Duration.zero) return;
    final cur = _a ?? _position;
    var next = _clampDur(cur + Duration(milliseconds: deltaMs), Duration.zero, _duration);

    // garde A < B (marge 200ms)
    if (_b != null && next >= _b!) {
      next = _clampDur(_b! - const Duration(milliseconds: 200), Duration.zero, _duration);
    }
    setState(() => _a = next);
    _save();
  }

  void _nudgeB(int deltaMs) {
    if (_duration == Duration.zero) return;
    final cur = _b ?? _position;
    var next = _clampDur(cur + Duration(milliseconds: deltaMs), Duration.zero, _duration);

    // garde A < B (marge 200ms)
    if (_a != null && next <= _a!) {
      next = _clampDur(_a! + const Duration(milliseconds: 200), Duration.zero, _duration);
    }
    setState(() {
      _b = next;
      if (_a != null && _b != null && _a! < _b!) _loopEnabled = true;
    });
    _save();
  }
  // =========================================================
  //                        A / B  LOGIC
  // =========================================================

  Duration _clampDur(Duration d, Duration min, Duration max) {
    if (d < min) return min;
    if (d > max) return max;
    return d;
  }

  // Enregistre/active une boucle en prefs quand A/B valides + boucle ON
  Future<void> _ensureLoopSaved() async {
    if (!_loopEnabled || _a == null || _b == null || !(_a! < _b!)) return;

    // Cherche une boucle similaire (tolérance 30 ms)
    int similarIndex = -1;
    for (int i = 0; i < _loops.length; i++) {
      final l = _loops[i];
      if ((l.aMs - _a!.inMilliseconds).abs() <= 30 &&
          (l.bMs - _b!.inMilliseconds).abs() <= 30) {
        similarIndex = i;
        break;
      }
    }

    if (similarIndex >= 0) {
      _activeLoopIndex = similarIndex;
    } else {
      final color = Color(_loopPalette[_loops.length % _loopPalette.length]);
      final saved = _SavedLoop(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: 'Boucle ${_loops.length + 1}',
        aMs: _a!.inMilliseconds,
        bMs: _b!.inMilliseconds,
        colorHex: color.value,
      );
      _loops.add(saved);
      _activeLoopIndex = _loops.length - 1;
    }

    await _saveLoopsToPrefs();

    // A/B “plats” + flag pour compat Editor
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setInt(_kPrefA, _a!.inMilliseconds);
    await _prefs!.setInt(_kPrefB, _b!.inMilliseconds);
    await _prefs!.setBool(_kPrefLoop, true);
    await _prefs!.setInt(_kPrefActiveLoop, _activeLoopIndex);
  }

  void _markA() {
    if (_duration == Duration.zero) return;
    final now = _position;
    if (_b == null) {
      setState(() { _a = now; _loopEnabled = false; });
    } else {
      setState(() { _a = now; _loopEnabled = (_a! < _b!); });
    }
    _save();
  }

  // B unifié : tap (keepA=false) => A = B - _quickGapMs + boucle ON ; long press (keepA=true) => B seul

  void _markB({bool keepA = false}) {
    if (_duration == Duration.zero) return;
    final now = _position;

    if (keepA) {
      // Appui long : poser B seulement
      setState(() {
        _b = _clampDur(now, Duration.zero, _duration);
        _loopEnabled = (_a != null && _b != null && _a! < _b!);
      });
    } else {
      // Tap : A = B - 4s (borné) + boucle ON
      var a = _clampDur(now - Duration(milliseconds: _quickGapMs), Duration.zero, _duration);
      var b = _clampDur(now, Duration.zero, _duration);
      if (b <= a) {
        b = _clampDur(a + const Duration(milliseconds: 200), Duration.zero, _duration);
      }
      setState(() {
        _a = a;
        _b = b;
        _loopEnabled = (_a! < _b!);
      });
    }

    _save();

    // ➜ si A/B valides, on persiste la boucle pour l’Editor
    if (_a != null && _b != null && _a! < _b!) {
      _persistLoopForEditor(_a!, _b!);
    }
  } // <— ICI se termine _markB (UNE seule accolade)
  void _clearLoop() {
    setState(() {
      _a = null;
      _b = null;
      _loopEnabled = false;
      _activeLoopIndex = -1; // si tu gères l’index actif
    });
    _save(); // si tu persistes l’état
  }
// imports à avoir en haut du fichier
// import 'dart:convert';
// import 'package:shared_preferences/shared_preferences.dart';

  Future<void> _persistLoopForEditor(Duration a, Duration b) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('loops.json');
    List<Map<String, dynamic>> data =
    (raw != null && raw.isNotEmpty) ? List<Map<String, dynamic>>.from(json.decode(raw)) : [];

    // anti-doublon : si la dernière entrée a/b est identique, ne réécris pas la liste
    if (data.isNotEmpty) {
      final last = data.last;
      final lastA = (last['a'] as num).toDouble();
      final lastB = (last['b'] as num).toDouble();
      final isSame = (lastA - a.inSeconds).abs() < 0.001 && (lastB - b.inSeconds).abs() < 0.001;
      if (isSame) {
        // juste réactiver la boucle et notifier
        await prefs.setInt('last.activeLoopIndex', data.length - 1);
        await prefs.setBool('last.loop', true);

        // 🔔 notifier l’Editor
        PlaybackService.I.updateLoop(a: a, b: b, enabled: true);
        return;
      }
    }

    // Ajouter une NOUVELLE boucle
    final newLoop = {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'a': a.inSeconds.toDouble(),
      'b': b.inSeconds.toDouble(),
      'name': 'Boucle ${data.length + 1}',
      'color': 0xFFFF9500, // tu peux changer la couleur par défaut si tu veux
    };
    data.add(newLoop);

    // Persister + activer
    await prefs.setString('loops.json', json.encode(data));
    await prefs.setInt('last.activeLoopIndex', data.length - 1);
    await prefs.setBool('last.loop', true);

    // 🔔 notifier l’Editor
    PlaybackService.I.updateLoop(a: a, b: b, enabled: true);
  }

  void _toggleLoopEnabled() {
    if (_a == null || _b == null || !(_a! < _b!)) {
      final half = Duration(milliseconds: (_quickGapMs / 2).round());
      var a = _clampDur(_position - half, Duration.zero, _duration);
      var b = _clampDur(_position + half, Duration.zero, _duration);
      if (b <= a) {
        b = _clampDur(a + const Duration(milliseconds: 200), Duration.zero, _duration);
      }
      setState(() { _a = a; _b = b; _loopEnabled = true; });
      _save();
      _ensureLoopSaved();
    } else {
      setState(() => _loopEnabled = !_loopEnabled);
      _save();
      if (_loopEnabled) _ensureLoopSaved();
    }
  }

  // =========================================================
  //                         VITESSE
  // =========================================================

  Future<void> _applySpeed(double v) async {
    final newSpeed = v.clamp(0.50, 1.50).toDouble();
    setState(() => _speed = double.parse(newSpeed.toStringAsFixed(2)));

    if (_isVideo) {
      final c = _video;
      if (c != null) {
        await c.setPlaybackSpeed(_speed);
      }
    } else {
      await _audio.setSpeed(_speed);
    }
    _save();
  }

  void _speedMinus() => _applySpeed(_speed - 0.05);
  void _speedPlus()  => _applySpeed(_speed + 0.05);

  // =========================================================
  //                       SPEED SHEET
  // =========================================================
  void _showSpeedSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: StatefulBuilder(
          builder: (context, setLocal) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Playback speed',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: Colors.orangeAccent,
                  inactiveTrackColor: Colors.white24,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 1.5,
                  divisions: 20,
                  label: '${_speed.toStringAsFixed(2)}x',
                  onChanged: (v) => setLocal(() => _speed = double.parse(v.toStringAsFixed(2))),
                  onChangeEnd: (v) => _applySpeed(v),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: _speedPresets.map((v) {
                  final active = (v == _speed);
                  return ChoiceChip(
                    label: Text('${v.toStringAsFixed(2)}x'),
                    selected: active,
                    selectedColor: Colors.orangeAccent,
                    backgroundColor: Colors.white12,
                    labelStyle: TextStyle(color: active ? Colors.black : Colors.white),
                    shape: StadiumBorder(
                      side: BorderSide(color: active ? Colors.orangeAccent : Colors.white24),
                    ),
                    onSelected: (_) {
                      _applySpeed(v);
                      setLocal(() {}); // refresh
                    },
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================
  //                 SETTINGS SHEET (Quick Loop)
  // =========================================================
  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final options = [2000, 4000, 8000, 16000]; // 2 / 4 / 8 / 16 s
        return StatefulBuilder(
          builder: (context, setLocal) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Réglages',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Durée de la boucle rapide (tap sur B) :',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: options.map((ms) {
                      final selected = (_quickGapMs == ms);
                      final label = '${(ms / 1000).round()} s';
                      return ChoiceChip(
                        label: Text(label),
                        selected: selected,
                        selectedColor: Colors.orangeAccent,
                        backgroundColor: Colors.white12,
                        labelStyle: TextStyle(color: selected ? Colors.black : Colors.white),
                        shape: StadiumBorder(
                          side: BorderSide(color: selected ? Colors.orangeAccent : Colors.white24),
                        ),
                        onSelected: (_) {
                          setState(() => _quickGapMs = ms);
                          setLocal(() {});
                          _save();
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Astuce : tap sur B = A = B − durée & boucle ON.\n'
                        'Appui long sur B = déplace seulement B.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // =========================================================
  //                            UI
  // =========================================================

  Color get _accent => const Color(0xFFFF9500);
  Color get _muted => Colors.white.withOpacity(0.6);

  @override
  Widget build(BuildContext context) {
    super.build(context); // important avec AutomaticKeepAliveClientMixin
    final title = _mediaPath == null ? 'Aucun fichier' : p.basename(_mediaPath!);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // ---------- top bar ----------
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Ouvrir…',
                    onPressed: _pickFile,
                    icon: const Icon(Icons.folder_open, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Réglages',
                    onPressed: _showSettingsSheet,
                    icon: const Icon(Icons.settings, color: Colors.white),
                  ),
                ],
              ),
            ),

            // ---------- media area + HUD ----------
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showHud,
                onDoubleTap: _playPause,
                onLongPress: _showHud,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _video?.value.aspectRatio ?? (9 / 16),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_isVideo) VideoPlayer(_video!) else _audioArea(),
                        _HudOverlay(
                          visible: _hudVisible,
                          isPlaying: _isPlaying,
                          position: _position,
                          duration: _duration,
                          onPlayPause: _playPause,
                          onBack: () => _seekBy(const Duration(seconds: -5)),
                          onFwd:  () => _seekBy(const Duration(seconds:  5)),
                          onScrub: (ms) {
                            _skipLoopOnce = true;
                            _seek(Duration(milliseconds: ms));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ---------- contrôles A/B + vitesse ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    _LoopBtn(label: 'A', onTap: _markA, active: _a != null, accent: _accent),
                    const SizedBox(width: 8),
                    _LoopBtn(
                      label: 'B',
                      onTap: () => _markB(keepA: false),
                      onLongPress: () => _markB(keepA: true),
                      active: _b != null,
                      accent: _accent,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: _loopEnabled ? 'Boucle activée' : 'Boucle désactivée',
                      onPressed: _toggleLoopEnabled,
                      icon: Icon(Icons.loop, color: _loopEnabled ? _accent : _muted),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Effacer A/B',
                      onPressed: _clearLoop,
                      icon: Icon(Icons.close, color: _muted),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _showSpeedSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${_speed.toStringAsFixed(2)}x',
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
// --- contrôles de zoom sur la timeline ---
            if (_hasDuration)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [

                    IconButton(
                      tooltip: 'Vue complète',
                      onPressed: _zoomReset,
                      icon: const Icon(Icons.fullscreen, color: Colors.white),
                    ),   IconButton(
                      tooltip: 'Zoom boucle A↔B',
                      onPressed: _zoomToLoop,
                      icon: const Icon(Icons.center_focus_strong, color: Colors.white),
                    ),
                  ],
                ),
              ),
            // ---------- timeline principale (A/B + drag handles) ----------
            // --- TIMELINE ÉPAISSE & CONTRASTÉE (style Player) ---
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
              child: SizedBox(
                height: 48, // même hauteur que le Player
                child: LayoutBuilder(
                  builder: (context, cons) {
                    final w = cons.maxWidth;
                    const trackH   = 12.0; // épaisseur de la piste remplie
                    const posLineW = 2.0;  // “cheveu” de lecture

                    final durMs = _duration.inMilliseconds.clamp(0, 1 << 30);
                    final posMs = _position.inMilliseconds.clamp(0, durMs == 0 ? 1 : durMs);
                    final p     = durMs == 0 ? 0.0 : posMs / durMs;

                    final aX = (_a == null || durMs == 0) ? null : (_a!.inMilliseconds / durMs) * w;
                    final bX = (_b == null || durMs == 0) ? null : (_b!.inMilliseconds / durMs) * w;

                    void seekAt(double dx) {
                      if (durMs == 0) return;
                      final rel = (dx / w).clamp(0.0, 1.0);
                      final ms  = (rel * durMs).round();
                      _skipLoopOnce = true;
                      _seek(Duration(milliseconds: ms));
                    }

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Fond encadré (visible sur simulateur)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white24),
                            ),
                          ),
                        ),

                        // Zone A↔B mise en avant
                        if (aX != null && bX != null && _a! < _b!)
                          Positioned(
                            left: aX.clamp(0.0, w),
                            width: (bX - aX).clamp(0.0, w),
                            top: (48 - 16) / 2,
                            height: 16,
                            child: Container(
                              decoration: BoxDecoration(
                                color: _accent.withOpacity(0.22),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),

                        // Remplissage de progression
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: p.clamp(0.0, 1.0),
                            child: Container(
                              height: trackH,
                              decoration: BoxDecoration(
                                color: _accent,
                                borderRadius: BorderRadius.circular(trackH / 2),
                              ),
                            ),
                          ),
                        ),

                        // Cheveu de lecture bien visible
                        if (durMs > 0)
                          Positioned(
                            left: (p * w - posLineW / 2).clamp(0.0, w - posLineW),
                            top: 4,
                            bottom: 4,
                            child: Container(width: posLineW, color: Colors.white70),
                          ),

                        // Scrub (tap/drag)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown:    (d) => seekAt(d.localPosition.dx),
                            onPanUpdate:  (d) => seekAt(d.localPosition.dx),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _audioArea() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Icon(
          (_audio.playing) ? Icons.graphic_eq : Icons.audiotrack,
          size: 72,
          color: _muted,
        ),
      ),
    );
  }

// === helper anti-crash pour clamp ===
  double _safeClamp(double v, double min, double max) {
    if (max < min) max = min; // borne haute jamais < borne basse
    return v.clamp(min, max);
  }
  Widget _timeline() {
    final durMs = _duration.inMilliseconds.toDouble().clamp(0.0, double.infinity);
    final posMs = _position.inMilliseconds.toDouble().clamp(0.0, durMs > 0 ? durMs : 0.0);

    String fmt(Duration d) => _fmt(d);

    const double trackH = 48;       // hauteur de la barre
    const double handleTouchW = 28; // zone tactile autour des poignées
    const double handleLineW  = 2;  // épaisseur du trait poignée
    const double posLineW     = 2;  // épaisseur du cheveu de lecture
    // dans _timeline()
    const int minGapMs = 200; // ✅ int, plus d’erreur

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Ligne d’infos (position courante)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(fmt(_position), style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12)),
            Text(fmt(_duration), style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12)),
          ],
        ),
        const SizedBox(height: 6),

        // ====== Timeline épaisse avec poignées ======
        LayoutBuilder(
          builder: (context, constraints) {
            final trackW = constraints.maxWidth;
            if (trackW <= 1) {
              return const SizedBox(height: trackH); // évite les calculs au 1er frame
            }
            // Si pas de durée (aucun fichier chargé), on ne calcule rien
            if (durMs <= 0) {
              return const SizedBox(height: trackH);
            }
            // Valeurs A/B en ms "affichées"
            final aMs = (_a ?? Duration.zero).inMilliseconds.toDouble().clamp(0.0, durMs > 0 ? durMs : 0.0);
            final bMs = (_b ?? (_duration == Duration.zero ? Duration.zero : _duration))
                .inMilliseconds
                .toDouble()
                .clamp(0.0, durMs > 0 ? durMs : 0.0);

            // APRÈS (respecte la fenêtre de vue si zoomée)
            final double start = _isZoomed ? _viewStartMs! : 0.0;
            final double end   = _isZoomed ? _viewEndMs!   : durMs;
            final double visibleLenRaw = (end - start);
            final double visibleLen = visibleLenRaw <= 0 ? 1.0 : visibleLenRaw;

            double msToX(double ms) => visibleLen <= 0
                ? 0
                : ((ms - start).clamp(0.0, visibleLen) / visibleLen) * trackW;

            double xToMs(double x) => start + ((x / trackW).clamp(0.0, 1.0) * visibleLen);

            double aX   = msToX(aMs);
            double bX   = msToX(bMs);
            double posX = msToX(posMs);

            return SizedBox(
              height: trackH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Fond de piste
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                  ),

                  // Scrub (drag n’importe où sur la piste)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanDown: (d) {
                        if (durMs <= 0) return;
                        final local = _safeClamp(d.localPosition.dx, 0.0, trackW);
                        final newMs = xToMs(local);
                        _skipLoopOnce = true;
                        _seek(Duration(milliseconds: newMs.round()));
                      },
                      onPanUpdate: (d) {
                        if (durMs <= 0) return;
                        final local = _safeClamp(d.localPosition.dx, 0.0, trackW);
                        final newMs = xToMs(local);
                        _skipLoopOnce = true;
                        _seek(Duration(milliseconds: newMs.round()));
                      },
                    ),
                  ),

                  // Zone A↔B mise en avant
                  if (_a != null && _b != null && _a! < _b! && durMs > 0)
                    Positioned(
                      left: aX,
                      right: trackW - bX,
                      top: (trackH / 2) - 6,
                      height: 12,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF9500).withOpacity(0.22),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),

                  // Poignée A (trait vertical)
                  if (durMs > 0)
                    Positioned(
                      left: _safeClamp(aX - handleTouchW / 2, 0.0, trackW - handleTouchW),
                      top: 0,
                      width: handleTouchW,
                      height: trackH,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanUpdate: (details) {
                          final newAX = (aX + details.delta.dx).clamp(0.0, trackW);
                          final newAMs = xToMs(newAX);

                          setState(() {
                            _a = Duration(milliseconds: newAMs.round());
                            // garantit A < B avec marge minimale
                            if (_b != null && _a! >= _b!) {
                              _b = _clampDur(_a! + const Duration(milliseconds: minGapMs), Duration.zero, _duration);
                            }
                          });
                        },
                        onPanEnd: (_) => _save(),
                        child: Center(
                          child: Container(width: handleLineW, height: trackH, color: const Color(0xFFFF9500)),
                        ),
                      ),
                    ),

                  // Poignée B (trait vertical)
                  if (durMs > 0)
                    Positioned(
                      left: _safeClamp(bX - handleTouchW / 2, 0.0, trackW - handleTouchW),
                      top: 0,
                      width: handleTouchW,
                      height: trackH,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanUpdate: (details) {
                          final newBX = (bX + details.delta.dx).clamp(0.0, trackW);
                          final newBMs = xToMs(newBX);

                          setState(() {
                            _b = Duration(milliseconds: newBMs.round());
                            // garantit A < B avec marge minimale
                            if (_a != null && _b! <= _a!) {
                              _a = _clampDur(_b! - const Duration(milliseconds: minGapMs), Duration.zero, _duration);
                            }
                          });
                        },
                        onPanEnd: (_) {
                          if (_a != null && _b != null && _a! < _b!) {
                            setState(() => _loopEnabled = true);
                          }
                          _save();
                        },
                        child: Center(
                          child: Container(width: handleLineW, height: trackH, color: const Color(0xFFFF9500)),
                        ),
                      ),
                    ),

                  // Cheveu de lecture
                  if (durMs > 0)
                    Positioned(
                      left: _safeClamp(posX - posLineW / 2, 0.0, trackW - posLineW),
                      top: 4,
                      bottom: 4,
                      child: Container(width: posLineW, color: Colors.white70),
                    ),
                ],
              ),
            );
          },
        ),

        const SizedBox(height: 8),

        // ====== Ligne A / B avec flèches de nudge ======
        Row(
          children: [
            // Bloc A
            _miniAB(
              label: 'A',
              time: _a ?? Duration.zero,
              onLessSmall: () => _nudgeA(-200),  // -0.2 s
              onMoreSmall: () => _nudgeA( 200),  // +0.2 s
              onLessBig:   () => _nudgeA(-2000), // -2 s
              onMoreBig:   () => _nudgeA( 2000), // +2 s
            ),
            const Spacer(),
            // Bloc B
            _miniAB(
              label: 'B',
              time: _b ?? Duration.zero,
              onLessSmall: () => _nudgeB(-200),
              onMoreSmall: () => _nudgeB( 200),
              onLessBig:   () => _nudgeB(-2000),
              onMoreBig:   () => _nudgeB( 2000),
            ),
          ],
        ),
      ],
    );
  }

// Petit widget interne pour A/B (flèches + temps)
  Widget _miniAB({
    required String label,
    required Duration time,
    required VoidCallback onLessSmall,
    required VoidCallback onMoreSmall,
    required VoidCallback onLessBig,
    required VoidCallback onMoreBig,
  }) {
    final muted = Colors.white.withOpacity(0.7);
    return Row(
      children: [
        Text(label, style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w800)),
        const SizedBox(width: 6),
        _tinyChevron('≪', onLessBig,  muted),
        const SizedBox(width: 2),
        _tinyChevron('‹',  onLessSmall, muted),
        const SizedBox(width: 6),
        Text(_fmt(time), style: TextStyle(color: muted)),
        const SizedBox(width: 6),
        _tinyChevron('›',  onMoreSmall, muted),
        const SizedBox(width: 2),
        _tinyChevron('≫', onMoreBig,  muted),
      ],
    );
  }

  Widget _tinyChevron(String txt, VoidCallback onTap, Color color) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(txt, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
      ),
    );
  }
  Widget _markerLabel(String s) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.6),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: _accent, width: 1),
    ),
    child: Text(
      s,
      style: TextStyle(color: _accent, fontWeight: FontWeight.w700, fontSize: 11),
    ),
  );

  String _fmt(Duration d) {
    final t = d.inMilliseconds < 0 ? Duration.zero : d;
    final h = t.inHours;
    final m = t.inMinutes.remainder(60);
    final s = t.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

// ===================== widgets utilitaires =====================

class _LoopBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress; // appui long supporté
  final bool active;
  final Color accent;

  const _LoopBtn({
    required this.label,
    required this.onTap,
    this.onLongPress,
    required this.active,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final off = Colors.white.withOpacity(0.35);
    return OutlinedButton(
      onPressed: onTap,
      onLongPress: onLongPress,
      style: OutlinedButton.styleFrom(
        foregroundColor: active ? accent : off,
        side: BorderSide(color: active ? accent : off, width: 1.4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        minimumSize: const Size(40, 36),
      ),
      child: Text(
        label,
        style: TextStyle(fontWeight: FontWeight.w700, color: active ? accent : off),
      ),
    );
  }
}

class _HudOverlay extends StatelessWidget {
  final bool visible;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final VoidCallback onPlayPause;
  final VoidCallback onBack;
  final VoidCallback onFwd;
  final void Function(int milliseconds) onScrub;

  const _HudOverlay({
    required this.visible,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.onPlayPause,
    required this.onBack,
    required this.onFwd,
    required this.onScrub,
  });

  @override
  Widget build(BuildContext context) {
    final durMs = duration.inMilliseconds.clamp(0, 1 << 31);
    final posMs = position.inMilliseconds.clamp(0, durMs);

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: visible ? 1.0 : 0.0,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Boutons -5 / Play-Pause / +5
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _HudIcon(icon: Icons.replay_5, onTap: onBack),
                    const SizedBox(width: 12),
                    _HudIcon(
                      icon: isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                      onTap: onPlayPause,
                      big: true,
                    ),
                    const SizedBox(width: 12),
                    _HudIcon(icon: Icons.forward_5, onTap: onFwd),
                  ],
                ),
                const SizedBox(height: 8),
                // Slider flottant indépendant
                SizedBox(
                  height: 28,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: Colors.orangeAccent,
                      inactiveTrackColor: Colors.white24,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: durMs > 0 ? posMs.toDouble() : 0,
                      min: 0,
                      max: durMs > 0 ? durMs.toDouble() : 1,
                      onChanged: durMs > 0 ? (v) {} : null,
                      onChangeEnd: durMs > 0 ? (v) => onScrub(v.round()) : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HudIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool big;
  const _HudIcon({required this.icon, required this.onTap, this.big = false});

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      radius: big ? 28 : 24,
      onTap: onTap,
      child: Icon(icon, size: big ? 44 : 28, color: Colors.white),
    );
  }
}

// ===================== Modèle boucles persistées =====================

class _SavedLoop {
  final String id;
  final String name;
  final int aMs;
  final int bMs;
  final int colorHex;

  _SavedLoop({
    required this.id,
    required this.name,
    required this.aMs,
    required this.bMs,
    required this.colorHex,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'a': aMs,
    'b': bMs,
    'color': colorHex,
  };

  static _SavedLoop fromJson(Map<String, dynamic> m) => _SavedLoop(
    id: m['id'] as String,
    name: m['name'] as String,
    aMs: m['a'] as int,
    bMs: m['b'] as int,
    colorHex: m['color'] as int,
  );
}