import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

/// ----- Modèle de marqueur (top-level, pas dans la classe de State)
class _Marker {
  String id;        // stable (pour delete)
  String name;      // "1", "2", ... (renommable)
  Duration at;      // position

  _Marker({required this.id, required this.name, required this.at});

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'ms': at.inMilliseconds};

  static _Marker fromJson(Map<String, dynamic> m) => _Marker(
    id: m['id'] as String,
    name: m['name'] as String,
    at: Duration(milliseconds: m['ms'] as int),
  );
}

/// Backing Player (HYBRIDE): Local + YouTube + Marqueurs "live"
class BackingPlayerScreen extends StatefulWidget {
  final String? initialYoutubeUrl; // optionnel

  const BackingPlayerScreen({super.key, this.initialYoutubeUrl});

  @override
  State<BackingPlayerScreen> createState() => _BackingPlayerScreenState();
}

enum _Source { local, youtube }

class _BackingPlayerScreenState extends State<BackingPlayerScreen> {
  // ------------------ état commun ------------------
  _Source _source = _Source.local;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // ------------------ Local ------------------
  String? _mediaPath;
  VideoPlayerController? _video;
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;

  bool get _isVideo => _video != null;
  bool get _isPlayingLocal =>
      _source == _Source.local &&
          (_isVideo ? (_video?.value.isPlaying ?? false) : _audio.playing);

  // ------------------ YouTube ------------------
  final TextEditingController _ytCtrl = TextEditingController();
  YoutubePlayerController? _yt;

  bool get _isPlayingYt =>
      _source == _Source.youtube && (_yt?.value.isPlaying ?? false);

  // ------------------ Marqueurs ------------------
  List<_Marker> _markers = [];
  int _autoMarkerCounter = 0;

  // ------------------ UI ------------------
  Color get _accent => const Color(0xFFFF9500);

  // ------------------ lifecycle ------------------
  @override
  void initState() {
    super.initState();
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
    _posSub?.cancel();
    _durSub?.cancel();
    _audio.dispose();
    _video?.dispose();
    _yt?.removeListener(_ytListener);
    _yt?.dispose();
    _ytCtrl.dispose();
    super.dispose();
  }

  // ------------------ Helpers ------------------
  String? _extractYoutubeId(String input) {
    final txt = input.trim();
    if (txt.isEmpty) return null;
    final uri = Uri.tryParse(txt);

    if (uri != null && uri.host.contains('youtu.be')) {
      if (uri.pathSegments.isNotEmpty) return uri.pathSegments.first;
    }
    if (uri != null && uri.queryParameters['v'] != null) {
      return uri.queryParameters['v'];
    }
    if (uri != null &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'shorts' &&
        uri.pathSegments.length >= 2) {
      return uri.pathSegments[1];
    }
    return YoutubePlayer.convertUrlToId(txt);
  }

  String? get _currentMediaKey {
    if (_source == _Source.youtube) {
      final id = _yt?.value.metaData.videoId;
      return (id == null || id.isEmpty) ? null : 'yt:$id';
    } else {
      return (_mediaPath == null) ? null : 'local:${_mediaPath!}';
    }
  }

  // ------------------ PERSISTENCE ------------------
  Future<void> _restoreLast() async {
    final sp = await SharedPreferences.getInstance();

    final src = sp.getString('backing.src');
    if (src == 'yt') _source = _Source.youtube;

    final lastUrl = sp.getString('backing.yt.url');
    if (lastUrl != null && lastUrl.isNotEmpty) {
      _ytCtrl.text = lastUrl;
      final id = _extractYoutubeId(lastUrl);
      if (id != null) _initYoutube(id);
    }

    final lastPath = sp.getString('backing.local.path');
    if (lastPath != null && File(lastPath).existsSync()) {
      await _openLocal(lastPath, autostart: false);
    }

    await _loadMarkers(); // en fonction de la source courante
    if (mounted) setState(() {});
  }

  Future<void> _saveCommon() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('backing.src', _source == _Source.youtube ? 'yt' : 'local');
    if (_source == _Source.youtube && _ytCtrl.text.isNotEmpty) {
      await sp.setString('backing.yt.url', _ytCtrl.text.trim());
    }
    if (_source == _Source.local && _mediaPath != null) {
      await sp.setString('backing.local.path', _mediaPath!);
    }
  }

  Future<void> _loadMarkers() async {
    final key = _currentMediaKey;
    _markers = [];
    _autoMarkerCounter = 0;
    if (key == null) {
      if (mounted) setState(() {});
      return;
    }
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('backing.markers.$key');
    if (raw != null && raw.isNotEmpty) {
      final List list = jsonDecode(raw) as List;
      _markers = list
          .map((e) => _Marker.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      // recalc auto-counter à partir de noms numériques
      final nums = _markers
          .map((m) => int.tryParse(m.name.trim()) ?? 0)
          .toList();
      _autoMarkerCounter = nums.isEmpty ? 0 : nums.reduce((a, b) => a > b ? a : b);
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveMarkers() async {
    final key = _currentMediaKey;
    if (key == null) return;
    final sp = await SharedPreferences.getInstance();
    final raw = jsonEncode(_markers.map((m) => m.toJson()).toList());
    await sp.setString('backing.markers.$key', raw);
  }

  // ------------------ LOCAL ------------------
  Future<void> _pickLocal() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'mov', 'm4v', 'mp3', 'wav', 'aac', 'm4a'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    setState(() => _source = _Source.local);
    await _openLocal(path);
    await _saveCommon();
    await _loadMarkers();
  }

  Future<void> _openLocal(String path, {bool autostart = true}) async {
    _posSub?.cancel();
    await _audio.stop();
    await _video?.pause();
    await _video?.dispose();
    _video = null;

    _mediaPath = path;
    final ext = p.extension(path).toLowerCase();

    if (<String>{'.mp4', '.mov', '.m4v'}.contains(ext)) {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      _video = c;
      _duration = c.value.duration;
      _position = Duration.zero;

      _posSub = Stream<Duration>.periodic(const Duration(milliseconds: 200), (_) {
        return _video?.value.position ?? Duration.zero;
      }).listen((pos) => setState(() => _position = pos));

      if (autostart) await c.play();
    } else {
      await _audio.setFilePath(path);
      _duration = _audio.duration ?? Duration.zero;
      _position = Duration.zero;

      _posSub = _audio.positionStream.listen((pos) {
        setState(() => _position = pos);
      });
      _durSub = _audio.durationStream.listen((d) {
        if (d != null) {
          _duration = d;
          if (mounted) setState(() {});
        }
      });

      if (autostart) await _audio.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _seekLocal(Duration d) async {
    d = d < Duration.zero ? Duration.zero : (d > _duration ? _duration : d);
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
      c.value.isPlaying ? await c.pause() : await c.play();
    } else {
      _audio.playing ? await _audio.pause() : await _audio.play();
    }
    setState(() {});
  }

  // ------------------ YOUTUBE ------------------
  void _ytListener() {
    if (!mounted || _source != _Source.youtube) return;
    final v = _yt!.value;
    _position = v.position;
    _duration = v.metaData.duration;
    setState(() {});
  }

  void _initYoutube(String id) {
    if (_yt == null) {
      _yt = YoutubePlayerController(
        initialVideoId: id,
        flags: const YoutubePlayerFlags(
          autoPlay: false,
          mute: false,
          enableCaption: false,
          useHybridComposition: true,
          controlsVisibleAtStart: true,
        ),
      )..addListener(_ytListener);
    } else {
      _yt!.load(id);
    }
    setState(() {});
    _saveCommon();
    _loadMarkers(); // charge les marqueurs de cette vidéo
  }

  void _playYtFromField() {
    final url = _ytCtrl.text.trim();
    final id = _extractYoutubeId(url);
    if (id == null) {
      _snack("URL YouTube invalide");
      return;
    }
    setState(() => _source = _Source.youtube);
    _initYoutube(id);
  }

  void _seekYt(Duration d) {
    if (_yt == null) return;
    final clamped =
    d < Duration.zero ? Duration.zero : (d > _duration ? _duration : d);
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

  // ------------------ MARQUEURS ------------------
  void _addMarkerAtCurrent() {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final name = (++_autoMarkerCounter).toString();
    final pos = _position; // ne pas stopper la lecture
    setState(() {
      _markers.add(_Marker(id: id, name: name, at: pos));
      _markers.sort((a, b) => a.at.compareTo(b.at));
    });
    _saveMarkers();
  }

  Future<void> _renameMarker(_Marker m) async {
    final ctrl = TextEditingController(text: m.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Renommer le marqueur', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nom',
            hintStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(onPressed: ()=> Navigator.pop(context), child: const Text('Annuler')),
          ElevatedButton(onPressed: ()=> Navigator.pop(context, ctrl.text.trim()), child: const Text('OK')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    setState(() => m.name = newName);
    _saveMarkers();
  }

  void _deleteMarker(String id) {
    setState(() => _markers.removeWhere((e) => e.id == id));
    _saveMarkers();
  }

  Future<void> _jumpToMarker(_Marker m) async {
    if (_source == _Source.youtube) {
      _seekYt(m.at);
    } else {
      await _seekLocal(m.at);
    }
  }

  // ------------------ UI helpers ------------------
  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0
        ? "${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}"
        : "${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}";
  }

  // ------------------ BUILD ------------------
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
        title: const Text("Backing Player"),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: "Ajouter un marqueur",
            icon: const Icon(Icons.bookmark_add_outlined, color: Colors.orangeAccent),
            onPressed: _addMarkerAtCurrent,
          ),
          IconButton(
            tooltip: "-5s",
            icon: const Icon(Icons.replay_5),
            onPressed: () {
              final t = _position - const Duration(seconds: 5);
              if (isYt) {
                _seekYt(t);
              } else {
                _seekLocal(t);
              }
            },
          ),
          IconButton(
            tooltip: "+5s",
            icon: const Icon(Icons.forward_5),
            onPressed: () {
              final t = _position + const Duration(seconds: 5);
              if (isYt) {
                _seekYt(t);
              } else {
                _seekLocal(t);
              }
            },
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
                  selected: isLocal,
                  onSelected: (_) async {
                    setState(() => _source = _Source.local);
                    await _saveCommon();
                    await _loadMarkers();
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text("YouTube"),
                  selected: isYt,
                  onSelected: (_) async {
                    setState(() => _source = _Source.youtube);
                    await _saveCommon();
                    await _loadMarkers();
                  },
                ),
                const Spacer(),
                if (isLocal)
                  ElevatedButton.icon(
                    onPressed: _pickLocal,
                    icon: const Icon(Icons.folder_open),
                    label: const Text("Ouvrir"),
                  ),
              ],
            ),
          ),

          // Barre YouTube (si source = yt)
          if (isYt)
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

          // Media view
          mediaView,

          // Infos (titre + temps)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    isYt
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

          // Marqueurs (chips) — avec long press via GestureDetector
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: _markers.isEmpty
                ? const Align(
              alignment: Alignment.centerLeft,
              child: Text("Aucun marqueur — appuie sur 🔖 pour en poser",
                  style: TextStyle(color: Colors.white54)),
            )
                : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _markers.map((m) {
                  final chip = Chip(
                    backgroundColor: const Color(0xFF2A2A2A),
                    label: Text(m.name,
                        style: const TextStyle(color: Colors.white)),
                  );
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => _jumpToMarker(m),
                      onLongPress: () async {
                        final action = await showModalBottomSheet<String>(
                          context: context,
                          backgroundColor: const Color(0xFF1A1A1A),
                          builder: (_) => SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.drive_file_rename_outline, color: Colors.white),
                                  title: const Text('Renommer', style: TextStyle(color: Colors.white)),
                                  onTap: () => Navigator.pop(context, 'rename'),
                                ),
                                ListTile(
                                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                  title: const Text('Supprimer', style: TextStyle(color: Colors.redAccent)),
                                  onTap: () => Navigator.pop(context, 'delete'),
                                ),
                              ],
                            ),
                          ),
                        );
                        if (action == 'rename') {
                          _renameMarker(m);
                        } else if (action == 'delete') {
                          _deleteMarker(m.id);
                        }
                      },
                      child: chip,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // Contrôles basiques
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                IconButton(
                  tooltip: "-5s",
                  icon: const Icon(Icons.replay_5, color: Colors.white),
                  onPressed: () {
                    final t = _position - const Duration(seconds: 5);
                    isYt ? _seekYt(t) : _seekLocal(t);
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
                    if (isYt) {
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
                    isYt ? _seekYt(t) : _seekLocal(t);
                  },
                ),
                if (isLocal)
                  IconButton(
                    tooltip: "Ouvrir un fichier",
                    icon: const Icon(Icons.folder_open, color: Colors.white70),
                    onPressed: _pickLocal,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}