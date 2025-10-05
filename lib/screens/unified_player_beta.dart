import 'dart:async';
import 'dart:io';

import '../core/library_service.dart';
import '../core/library_item.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

/// Player unifié (BETA) : fichier local (audio/vidéo) OU YouTube, avec A/B loop simple.
class UnifiedPlayerBeta extends StatefulWidget {
  final String? initialYoutubeUrl; // optionnel (permet d'ouvrir directement une URL YT)

  const UnifiedPlayerBeta({
    super.key,
    this.initialYoutubeUrl,
  });

  @override
  State<UnifiedPlayerBeta> createState() => _UnifiedPlayerBetaState();
}

enum _Source { local, youtube }

class _UnifiedPlayerBetaState extends State<UnifiedPlayerBeta> {
  // -------------------- état commun --------------------
  final LibraryService _libraryService = LibraryService();
  _Source _source = _Source.local;

  // A/B loop
  Duration? _a;
  Duration? _b;
  bool _loopEnabled = false;
  bool _skipLoopOnce = false;

  // position/durée communes
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // -------------------- LOCAL --------------------
  String? _mediaPath;
  VideoPlayerController? _video;
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;

  bool get _isVideo => _video != null;
  bool get _isPlayingLocal =>
      _source == _Source.local &&
          (_isVideo ? (_video?.value.isPlaying ?? false) : _audio.playing);

  // -------------------- YOUTUBE --------------------
  final TextEditingController _ytCtrl = TextEditingController();
  YoutubePlayerController? _yt;

  bool get _isPlayingYt =>
      _source == _Source.youtube && (_yt?.value.isPlaying ?? false);

  // marge minimale entre A et B
  static const int _minABGapMs = 200;

  // --- ZOOM ---
  double _zoomFactor = 1.0; // 1.0 = vue globale
  static const double _minZoom = 1.0;
  static const double _maxZoom = 20.0;

  void _zoomOut() {
    setState(() => _zoomFactor = (_zoomFactor / 1.25).clamp(_minZoom, _maxZoom));
  }

  void _zoomIn() {
    setState(() => _zoomFactor = (_zoomFactor * 1.25).clamp(_minZoom, _maxZoom));
  }

  // --- couleurs (mêmes que Player) ---
  Color get _accent => const Color(0xFFFF9500);

  // === helpers ===
  double _safeClamp(double v, double min, double max) {
    if (max < min) max = min;
    return v.clamp(min, max).toDouble();
  }

  /// Extraction d'ID YouTube robuste (watch?v=, youtu.be/, shorts/, etc.)
  String? _extractYoutubeId(String input) {
    final txt = input.trim();
    if (txt.isEmpty) return null;

    final uri = Uri.tryParse(txt);

    // youtu.be/<id>
    if (uri != null && uri.host.contains('youtu.be')) {
      if (uri.pathSegments.isNotEmpty) {
        return uri.pathSegments.first;
      }
    }

    // youtube.com/watch?v=<id>
    if (uri != null && uri.queryParameters['v'] != null) {
      return uri.queryParameters['v'];
    }

    // youtube.com/shorts/<id>
    if (uri != null &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'shorts' &&
        uri.pathSegments.length >= 2) {
      return uri.pathSegments[1];
    }

    // fallback
    return YoutubePlayer.convertUrlToId(txt);
  }

  String? _currentYoutubeUrl() {
    if (_source != _Source.youtube) return null;

    final txt = _ytCtrl.text.trim();
    if (txt.isNotEmpty) return txt;

    final id = _yt?.value.metaData.videoId;
    if (id != null && id.isNotEmpty) return "https://youtu.be/$id";

    return null;
  }

  String _currentTitle() {
    if (_source == _Source.youtube) {
      return _yt?.value.metaData.title ?? "Vidéo YouTube";
    }
    return _mediaPath != null ? p.basename(_mediaPath!) : "Média local";
  }

  Future<void> _saveToLibrary(String url, String title) async {
    final item = LibraryItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      url: url,
      source: 'youtube',
      notes: '',
    );
    await _libraryService.addItem(item);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ Vidéo ajoutée à l’Atelier')),
    );
  }

  // -------------------- lifecycle --------------------
  @override
  void initState() {
    super.initState();

    // Si on reçoit une URL YT initiale, on bascule sur YouTube et on charge direct.
    if (widget.initialYoutubeUrl != null &&
        widget.initialYoutubeUrl!.trim().isNotEmpty) {
      _source = _Source.youtube;
      _ytCtrl.text = widget.initialYoutubeUrl!.trim();
      final id = _extractYoutubeId(_ytCtrl.text);
      if (id != null) _initYoutube(id);
    }

    _restoreLast();
  }

  @override
  void dispose() {
    // local
    _posSub?.cancel();
    _durSub?.cancel();
    _audio.dispose();
    _video?.dispose();
    // yt
    _yt?.removeListener(_ytListener);
    _yt?.dispose();
    _ytCtrl.dispose();
    super.dispose();
  }

  // -------------------- PERSISTENCE --------------------
  Future<void> _restoreLast() async {
    final sp = await SharedPreferences.getInstance();

    // Ne pas écraser la source si une URL initiale a été fournie
    if (widget.initialYoutubeUrl == null ||
        widget.initialYoutubeUrl!.trim().isEmpty) {
      final src = sp.getString('unified.src');
      _source = (src == 'yt') ? _Source.youtube : _Source.local;
    }

    // restaurer dernière vidéo YouTube
    final lastUrl = sp.getString('unified.yt.url');
    if (lastUrl != null && lastUrl.isNotEmpty) {
      _ytCtrl.text = lastUrl;
      final id = _extractYoutubeId(lastUrl);
      if (id != null) _initYoutube(id);
    }

    // restaurer dernier média local
    final lastPath = sp.getString('unified.local.path');
    if (lastPath != null && File(lastPath).existsSync()) {
      await _openLocal(lastPath, autostart: false);
    }

    // restaurer A/B
    final aMs = sp.getInt('unified.ab.a') ?? -1;
    final bMs = sp.getInt('unified.ab.b') ?? -1;
    _a = aMs >= 0 ? Duration(milliseconds: aMs) : null;
    _b = bMs >= 0 ? Duration(milliseconds: bMs) : null;
    _loopEnabled = sp.getBool('unified.ab.loop') ?? false;

    if (mounted) setState(() {});
  }

  Future<void> _saveCommon() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('unified.src', _source == _Source.youtube ? 'yt' : 'local');
    await sp.setInt('unified.ab.a', _a?.inMilliseconds ?? -1);
    await sp.setInt('unified.ab.b', _b?.inMilliseconds ?? -1);
    await sp.setBool('unified.ab.loop', _loopEnabled);

    if (_source == _Source.youtube && _ytCtrl.text.isNotEmpty) {
      await sp.setString('unified.yt.url', _ytCtrl.text.trim());
    }
    if (_source == _Source.local && _mediaPath != null) {
      await sp.setString('unified.local.path', _mediaPath!);
    }
  }

  // -------------------- LOCAL: open & control --------------------
  Future<void> _pickLocal() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'mov', 'm4v', 'mp3', 'wav', 'aac', 'm4a'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    await _openLocal(path);
  }

  Future<void> _openLocal(String path, {bool autostart = true}) async {
    // cleanup
    _posSub?.cancel();
    await _audio.stop();
    await _video?.pause();
    await _video?.dispose();
    _video = null;

    _mediaPath = path;
    final ext = p.extension(path).toLowerCase();

    if (<String>{'.mp4', '.mov', '.m4v'}.contains(ext)) {
      // vidéo
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      _video = c;
      _duration = c.value.duration;
      _position = Duration.zero;

      _posSub = Stream<Duration>.periodic(const Duration(milliseconds: 200), (_) {
        return _video?.value.position ?? Duration.zero;
      }).listen(_onTickLocal);

      if (autostart) await c.play();
    } else {
      // audio
      await _audio.setFilePath(path);
      _duration = _audio.duration ?? Duration.zero;
      _position = Duration.zero;

      _posSub = _audio.positionStream.listen(_onTickLocal);
      _durSub = _audio.durationStream.listen((d) {
        if (d != null) {
          _duration = d;
          if (mounted) setState(() {});
        }
      });

      if (autostart) await _audio.play();
    }

    setState(() {});
    _saveCommon();
  }

  void _onTickLocal(Duration pos) {
    if (!mounted) return;
    if (_duration == Duration.zero) return;

    // skip 1er tick après seek manuel
    if (_skipLoopOnce) {
      _skipLoopOnce = false;
      setState(() => _position = pos);
      return;
    }

    // A/B loop
    if (_loopEnabled && _a != null && _b != null && _a! < _b!) {
      if (pos >= _b!) {
        _seekLocal(_a!);
        return;
      }
    }
    setState(() => _position = pos);
  }

  Future<void> _seekLocal(Duration d) async {
    d = _clampDur(d, Duration.zero, _duration);
    if (_isVideo) {
      await _video!.seekTo(d);
    } else {
      await _audio.seek(d);
    }
    setState(() => _position = d);
  }

  Future<void> _playPauseLocal() async {
    if (_mediaPath == null) {
      await _pickLocal();
      return;
    }
    if (_isVideo) {
      final c = _video!;
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        await c.play();
      }
    } else {
      if (_audio.playing) {
        await _audio.pause();
      } else {
        await _audio.play();
      }
    }
  }

  // -------------------- YOUTUBE: init & control --------------------
  void _ytListener() {
    if (!mounted || _source != _Source.youtube) return;
    final v = _yt!.value;
    _position = v.position;
    _duration = v.metaData.duration;

    // A/B loop (seek via controller)
    if (_loopEnabled && _a != null && _b != null && _a! < _b!) {
      if (_position >= _b!) {
        _yt!.seekTo(_a!);
      }
    }
    setState(() {});
  }

  void _initYoutube(String id) {
    // (optionnel) reset léger de la boucle à chaque nouvelle vidéo
    _loopEnabled = false;
    _a = null;
    _b = null;

    if (_yt == null) {
      _yt = YoutubePlayerController(
        initialVideoId: id,
        flags: const YoutubePlayerFlags(
          autoPlay: false,
          mute: false,
          useHybridComposition: true, // ✅ important sur Android récents
          enableCaption: false,
          controlsVisibleAtStart: true,
        ),
      )..addListener(_ytListener);
    } else {
      _yt!.load(id);
    }
    setState(() {});
  }

  void _playYtFromField() {
    final url = _ytCtrl.text.trim();
    final id = _extractYoutubeId(url);
    if (id == null) {
      _snack("URL YouTube invalide");
      return;
    }
    _initYoutube(id);
    _saveCommon();
  }

  void _seekYt(Duration d) {
    if (_yt == null) return;
    final clamped = _clampDur(d, Duration.zero, _duration);
    _yt!.seekTo(clamped);
    _position = clamped;
    setState(() {});
  }

  Future<void> _playPauseYt() async {
    if (_yt == null) {
      _playYtFromField();
      return;
    }
    if (_yt!.value.isPlaying) {
      _yt!.pause();
    } else {
      _yt!.play();
    }
  }

  // -------------------- A/B helpers --------------------
  Duration _clampDur(Duration d, Duration min, Duration max) {
    if (d < min) return min;
    if (d > max) return max;
    return d;
  }

  void _markA() {
    final now = _position;
    setState(() {
      _a = now;
      if (_b != null) _loopEnabled = (_a! < _b!);
    });
    _saveCommon();
  }

  void _markB() {
    final now = _position;
    setState(() {
      _b = now;
      if (_a != null) _loopEnabled = (_a! < _b!);
    });
    _saveCommon();
  }

  void _toggleLoop() {
    if (_a == null || _b == null || !(_a! < _b!)) return;
    setState(() => _loopEnabled = !_loopEnabled);
    _saveCommon();
  }

  void _clearAB() {
    setState(() {
      _a = null;
      _b = null;
      _loopEnabled = false;
    });
    _saveCommon();
  }

  /// Loupe : crée une boucle de 4s terminant à la position actuelle (A = B − 4s), active la boucle et seek sur A.
  void _quickLoop() {
    if (_duration == Duration.zero) return;

    const gap = Duration(seconds: 4);
    var b = _position;
    var a = b - gap;

    // bornes + écart mini
    if (a < Duration.zero) a = Duration.zero;
    if (b <= a + const Duration(milliseconds: _minABGapMs)) {
      b = a + const Duration(milliseconds: _minABGapMs);
      if (b > _duration) {
        b = _duration;
        a = b - const Duration(milliseconds: _minABGapMs);
        if (a < Duration.zero) a = Duration.zero;
      }
    }

    setState(() {
      _a = a;
      _b = b;
      _loopEnabled = true;
    });

    // on repart à A pour entendre tout de suite la boucle
    if (_source == _Source.youtube) {
      _seekYt(_a!);
    } else {
      _skipLoopOnce = true;
      _seekLocal(_a!);
    }

    _saveCommon();
  }

  // ==================== NUDGE (chevrons) ====================
  void _nudgeA(int deltaMs) {
    if (_duration == Duration.zero) return;
    final cur = _a ?? _position;
    var next = _clampDur(
      cur + Duration(milliseconds: deltaMs),
      Duration.zero,
      _duration,
    );

    if (_b != null && next >= _b!) {
      next = _clampDur(
        _b! - const Duration(milliseconds: _minABGapMs),
        Duration.zero,
        _duration,
      );
    }
    setState(() => _a = next);
    _saveCommon();
  }

  void _nudgeB(int deltaMs) {
    if (_duration == Duration.zero) return;
    final cur = _b ?? _position;
    var next = _clampDur(
      cur + Duration(milliseconds: deltaMs),
      Duration.zero,
      _duration,
    );

    if (_a != null && next <= _a!) {
      next = _clampDur(
        _a! + const Duration(milliseconds: _minABGapMs),
        Duration.zero,
        _duration,
      );
    }
    setState(() {
      _b = next;
      if (_a != null && _b != null && _a! < _b!) _loopEnabled = true;
    });
    _saveCommon();
  }

  Widget _tinyChevron(String txt, VoidCallback onTap, Color color) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white38),
        ),
        child: Text(txt, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
      ),
    );
  }

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
        Text(label, style: TextStyle(color: _accent, fontWeight: FontWeight.w800)),
        const SizedBox(width: 6),
        _tinyChevron('≪', onLessBig, muted), // -2 s
        const SizedBox(width: 2),
        _tinyChevron('‹', onLessSmall, muted), // -0.2 s
        const SizedBox(width: 6),
        Text(_fmt(time), style: TextStyle(color: muted)),
        const SizedBox(width: 6),
        _tinyChevron('›', onMoreSmall, muted), // +0.2 s
        const SizedBox(width: 2),
        _tinyChevron('≫', onMoreBig, muted), // +2 s
      ],
    );
  }

  // -------------------- UI helpers --------------------
  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0
        ? "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}"
        : "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  // ===== Timeline épaisse (style Player) — boutons de zoom latéraux fixés =====
  Widget _timelineThick() {
    const double barH = 48.0; // hauteur totale
    const double sideBtnW = 56.0; // largeur des boutons latéraux

    return SizedBox(
      height: barH,
      child: Row(
        children: [
          SizedBox(width: sideBtnW, child: _zoomSideButton(isLeft: true)),
          Expanded(child: _timelineCore(barH)),
          SizedBox(width: sideBtnW, child: _zoomSideButton(isLeft: false)),
        ],
      ),
    );
  }

  // Cœur de la timeline (la barre elle-même)
  Widget _timelineCore(double barH) {
    final double durMs = _duration.inMilliseconds.toDouble();
    final double posMs = _position.inMilliseconds.toDouble();

    const double posLineW = 2.0; // cheveu de lecture
    const double abBandH = 12.0; // bande A–B
    const double handleW = 2.0; // épaisseur visuelle poignée
    const double handleTouchW = 28; // zone tactile poignée

    if (durMs <= 0) {
      return Container(
        height: barH,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
      );
    }

    return LayoutBuilder(
      builder: (ctx, cons) {
        final double w = cons.maxWidth;

        // ==== Fenêtre de zoom (startMs..endMs) ====
        double window = durMs / _zoomFactor;

        final double? aMs = _a?.inMilliseconds.toDouble();
        final double? bMs = _b?.inMilliseconds.toDouble();
        final bool hasLoop =
            _loopEnabled && aMs != null && bMs != null && aMs! < bMs!;
        final double loopSize = hasLoop ? (bMs! - aMs!) : 0.0;
        const double pad = 400.0; // ~0.4s de marge autour de la boucle

        if (hasLoop) {
          final double minWin = (loopSize + pad).clamp(100.0, durMs);
          if (window < minWin) window = minWin;
        }

        final double centerMs = hasLoop ? (aMs! + bMs!) / 2.0 : posMs;
        double startMs = centerMs - window / 2.0;
        double endMs = centerMs + window / 2.0;

        if (startMs < 0) {
          endMs -= startMs;
          startMs = 0;
        }
        if (endMs > durMs) {
          startMs -= (endMs - durMs);
          endMs = durMs;
          if (startMs < 0) startMs = 0;
        }
        final double visibleLen =
        (endMs - startMs) <= 0 ? 1.0 : (endMs - startMs);

        double msToX(double ms) =>
            ((ms - startMs).clamp(0.0, visibleLen) / visibleLen) * w;
        double xToMs(double x) =>
            startMs + ((x / w).clamp(0.0, 1.0) * visibleLen);

        final double posX = msToX(posMs);
        final double? aX = (aMs == null) ? null : msToX(aMs);
        final double? bX = (bMs == null) ? null : msToX(bMs);

        Future<void> _seekAt(double dx) async {
          final ms = xToMs(_safeClamp(dx, 0.0, w)).round();
          final d = Duration(milliseconds: ms);
          if (_source == _Source.youtube) {
            _seekYt(d);
          } else {
            _skipLoopOnce = true;
            await _seekLocal(d);
          }
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Fond encadré bien visible
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white38),
                ),
              ),
            ),

            // Zone A↔B
            if (hasLoop && aX != null && bX != null)
              Positioned(
                left: aX,
                right: (w - bX),
                top: (barH - abBandH) / 2,
                height: abBandH,
                child: Container(
                  decoration: BoxDecoration(
                    color: _accent.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),

            // Progression (remplissage)
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: _safeClamp(posX / w, 0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),

            // Cheveu de lecture
            Positioned(
              left: _safeClamp(posX - posLineW / 2, 0.0, w - posLineW),
              top: 4,
              bottom: 4,
              child: Container(width: posLineW, color: Colors.white),
            ),

            // Poignée A
            if (aX != null)
              Positioned(
                left: _safeClamp(aX - handleTouchW / 2, 0.0, w - handleTouchW),
                top: 0,
                width: handleTouchW,
                height: barH,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanUpdate: (d) {
                    final newAX = _safeClamp(aX + d.delta.dx, 0.0, w);
                    final newAMs = xToMs(newAX).round();
                    setState(() {
                      _a = Duration(milliseconds: newAMs);
                      if (_b != null && _a! >= _b!) {
                        _b = _clampDur(
                          _a! + const Duration(milliseconds: _minABGapMs),
                          Duration.zero,
                          _duration,
                        );
                      }
                    });
                  },
                  onPanEnd: (_) => _saveCommon(),
                  child: Center(
                    child: Container(width: handleW, height: barH, color: _accent),
                  ),
                ),
              ),

            // Poignée B
            if (bX != null)
              Positioned(
                left: _safeClamp(bX - handleTouchW / 2, 0.0, w - handleTouchW),
                top: 0,
                width: handleTouchW,
                height: barH,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanUpdate: (d) {
                    final newBX = _safeClamp(bX + d.delta.dx, 0.0, w);
                    final newBMs = xToMs(newBX).round();
                    setState(() {
                      _b = Duration(milliseconds: newBMs);
                      if (_a != null && _b! <= _a!) {
                        _a = _clampDur(
                          _b! - const Duration(milliseconds: _minABGapMs),
                          Duration.zero,
                          _duration,
                        );
                      }
                    });
                  },
                  onPanEnd: (_) {
                    if (_a != null && _b != null && _a! < _b!) {
                      setState(() => _loopEnabled = true);
                    }
                    _saveCommon();
                  },
                  child: Center(
                    child: Container(width: handleW, height: barH, color: _accent),
                  ),
                ),
              ),

            // Scrub global tap/drag
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _seekAt(d.localPosition.dx),
                onPanUpdate: (d) => _seekAt(d.localPosition.dx),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _zoomSideButton({required bool isLeft}) {
    return Align(
      alignment: Alignment.center,
      child: IconButton(
        onPressed: isLeft ? _zoomOut : _zoomIn,
        icon: Icon(isLeft ? Icons.zoom_out : Icons.zoom_in),
        color: Colors.white,
        tooltip: isLeft ? "Zoom −" : "Zoom +",
      ),
    );
  }

  // -------------------- BUILD --------------------
  @override
  Widget build(BuildContext context) {
    final isYt = _source == _Source.youtube;
    final isLocal = _source == _Source.local;

    // Vue média
    Widget mediaView;
    if (isYt) {
      mediaView = AspectRatio(
        aspectRatio: 16 / 9,
        child: _yt == null
            ? Container(
          color: const Color(0xFF0f0f0f),
          child: const Center(
            child: Text("Aucune vidéo YouTube",
                style: TextStyle(color: Colors.white54)),
          ),
        )
            : YoutubePlayer(
          controller: _yt!,
          showVideoProgressIndicator: true,
          progressIndicatorColor: Colors.redAccent,
        ),
      );
    } else {
      mediaView = AspectRatio(
        aspectRatio: _isVideo ? (_video!.value.aspectRatio) : (16 / 9),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_isVideo)
              VideoPlayer(_video!)
            else
              Container(
                color: Colors.black,
                child: const Center(
                  child: Icon(Icons.audiotrack, size: 72, color: Colors.white54),
                ),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Unified Player (BETA)"),
        backgroundColor: Colors.black,
        actions: [
          if (_source == _Source.youtube)
            IconButton(
              tooltip: "Ajouter à l’Atelier",
              icon: const Icon(Icons.playlist_add, color: Colors.orangeAccent),
              onPressed: () async {
                final url = _currentYoutubeUrl();
                if (url == null) {
                  _snack("Aucune URL YouTube à enregistrer.");
                  return;
                }
                final title = _currentTitle();
                await _saveToLibrary(url, title);
              },
            ),
          IconButton(
            tooltip: "Marquer A",
            icon: const Icon(Icons.flag_circle_outlined),
            onPressed: _markA,
          ),
          IconButton(
            tooltip: "Marquer B",
            icon: const Icon(Icons.outlined_flag),
            onPressed: _markB,
          ),
          IconButton(
            tooltip: _loopEnabled ? "Boucle ON" : "Boucle OFF",
            icon: Icon(Icons.loop, color: _loopEnabled ? _accent : Colors.white),
            onPressed: _toggleLoop,
          ),
          // --- Bouton REPLAY + effacer juste à côté ---
          TextButton.icon(
            onPressed: _quickLoop,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.center_focus_strong),
            label: const Text("Replay"),
          ),
          IconButton(
            tooltip: "Effacer la boucle",
            icon: const Icon(Icons.clear),
            onPressed: _clearAB,
          ),
        ],
      ),
      body: Column(
        children: [
          // Sélecteur de source
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text("Local"),
                  selected: _source == _Source.local,
                  onSelected: (_) {
                    setState(() => _source = _Source.local);
                    _saveCommon();
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text("YouTube"),
                  selected: _source == _Source.youtube,
                  onSelected: (_) {
                    setState(() => _source = _Source.youtube);
                    _saveCommon();
                  },
                ),
                const Spacer(),
                if (_source == _Source.local)
                  ElevatedButton.icon(
                    onPressed: _pickLocal,
                    icon: const Icon(Icons.folder_open),
                    label: const Text("Ouvrir"),
                  ),
              ],
            ),
          ),

          // Barre YouTube (si source = yt)
          if (_source == _Source.youtube)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ytCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: "Colle une URL YouTube…",
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: const Color(0xFF1a1a1a),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white24),
                        ),
                      ),
                      onSubmitted: (_) => _playYtFromField(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _playYtFromField,
                    icon: const Icon(Icons.play_arrow, color: Colors.white),
                  ),
                ],
              ),
            ),

          // Vue média – plein largeur
          mediaView,

          // Infos (titre + temps)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _source == _Source.youtube
                        ? (_yt?.value.metaData.title ?? "—")
                        : (_mediaPath != null ? p.basename(_mediaPath!) : "—"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_fmt(_position), style: const TextStyle(color: Colors.white70)),
                const Text(" / "),
                Text(_fmt(_duration), style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),

          // Timeline large – avec boutons de zoom latéraux fixés
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
            child: _timelineThick(),
          ),

          // --- Affinage A/B (flèches) ---
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                _miniAB(
                  label: 'A',
                  time: _a ?? Duration.zero,
                  onLessSmall: () => _nudgeA(-200), // -0.2 s
                  onMoreSmall: () => _nudgeA(200), // +0.2 s
                  onLessBig: () => _nudgeA(-2000), // -2 s
                  onMoreBig: () => _nudgeA(2000), // +2 s
                ),
                const Spacer(),
                _miniAB(
                  label: 'B',
                  time: _b ?? Duration.zero,
                  onLessSmall: () => _nudgeB(-200),
                  onMoreSmall: () => _nudgeB(200),
                  onLessBig: () => _nudgeB(-2000),
                  onMoreBig: () => _nudgeB(2000),
                ),
              ],
            ),
          ),

          // Contrôles simples + Replay + Effacer à côté
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                IconButton(
                  tooltip: "-5s",
                  icon: const Icon(Icons.replay_5, color: Colors.white),
                  onPressed: () {
                    final t = _position - const Duration(seconds: 5);
                    if (_source == _Source.youtube) {
                      _seekYt(t);
                    } else {
                      _skipLoopOnce = true;
                      _seekLocal(t);
                    }
                  },
                ),
                IconButton(
                  icon: Icon(
                    (isYt && _isPlayingYt) || (isLocal && _isPlayingLocal)
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: Colors.white,
                    size: 38,
                  ),
                  onPressed: () {
                    if (_source == _Source.youtube) {
                      _playPauseYt();
                    } else {
                      _playPauseLocal();
                    }
                  },
                ),
                IconButton(
                  tooltip: "+5s",
                  icon: const Icon(Icons.forward_5, color: Colors.white),
                  onPressed: () {
                    final t = _position + const Duration(seconds: 5);
                    if (_source == _Source.youtube) {
                      _seekYt(t);
                    } else {
                      _skipLoopOnce = true;
                      _seekLocal(t);
                    }
                  },
                ),

                // Replay + effacer la boucle juste à côté
                OutlinedButton.icon(
                  onPressed: _quickLoop,
                  icon: const Icon(Icons.replay_circle_filled),
                  label: const Text("REPLAY"),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _accent, // texte & icône orange
                    side: BorderSide(color: _accent, width: 2), // bordure orange
                    shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    textStyle:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                IconButton(
                  tooltip: "Effacer la boucle",
                  icon: const Icon(Icons.clear, color: Colors.redAccent),
                  onPressed: _clearAB,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}