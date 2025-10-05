import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class BackingTrackScreen extends StatefulWidget {
  const BackingTrackScreen({super.key});
  @override
  State<BackingTrackScreen> createState() => _BackingTrackScreenState();
}

class _BackingTrackScreenState extends State<BackingTrackScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  // ================== prefs keys ==================
  static const _kLastPath = 'backing.lastPath';
  static const _kLastPosMs = 'backing.lastPosMs';
  static const _kRecents = 'backing.recents';
  static const int _kMaxRecents = 8;

  // ================== lecteur ==================
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;

  String? _mediaPath;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool get _hasDuration => _duration > Duration.zero;

  // ================== marqueurs ==================
  final List<_Marker> _markers = [];
  SharedPreferences? _prefs;

  // ================== récents ==================
  final List<String> _recents = []; // chemins absolus

  // ================== style ==================
  Color get _accent => const Color(0xFFFF9500);
  Color get _muted => Colors.white.withOpacity(0.7);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreOnLaunch(); // charge prefs + dernière session
  }

  Future<void> _restoreOnLaunch() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadRecents();

    // Tenter de rouvrir le dernier fichier
    final lastPath = _prefs!.getString(_kLastPath);
    final lastPosMs = _prefs!.getInt(_kLastPosMs) ?? 0;

    if (lastPath != null && File(lastPath).existsSync()) {
      await _openPath(lastPath, autostart: false);
      if (lastPosMs > 0) {
        final d = Duration(milliseconds: lastPosMs);
        await _seek(d);
      }
    } else {
      setState(() {}); // écran vide
    }
  }

  @override
  void dispose() {
    _saveSession(); // enregistre position + chemin
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _durSub?.cancel();
    _audio.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _saveSession();
    }
  }

  @override
  bool get wantKeepAlive => true;

  // ================== ouverture média ==================
  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'aac', 'm4a', 'flac', 'mp4', 'm4v', 'mov'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    await _openPath(path);
  }

  Future<void> _openPath(String path, {bool autostart = true}) async {
    // stop courant
    await _audio.stop();
    _posSub?.cancel();
    _durSub?.cancel();

    _mediaPath = path;
    _position = Duration.zero;
    _duration = Duration.zero;
    setState(() {});

    // configure audio
    await _audio.setFilePath(path);
    _duration = _audio.duration ?? Duration.zero;

    // streams
    _posSub = _audio.positionStream.listen((d) {
      if (!mounted) return;
      setState(() => _position = d);
    });

    _durSub = _audio.durationStream.listen((d) {
      if (!mounted) return;
      if (d != null) setState(() => _duration = d);
    });

    // charge marqueurs pour ce fichier
    await _loadMarkersForPath();

    // mémorise le chemin + MAJ récents
    _saveSession();
    _touchRecent(path);

    if (autostart) {
      await _audio.play();
    }
    setState(() {});
  }

  // ================== helpers ==================
  Future<void> _seek(Duration d) async {
    if (!_hasDuration) return;
    final clamped = _clampDur(d, Duration.zero, _duration);
    await _audio.seek(clamped);
    setState(() => _position = clamped);
  }

  Duration _clampDur(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  double _safeClampDouble(double v, double lo, double hi) {
    if (hi < lo) hi = lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
  }

  String _fmt(Duration d) {
    final t = d < Duration.zero ? Duration.zero : d;
    final h = t.inHours;
    final m = t.inMinutes.remainder(60);
    final s = t.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ================== session persistence ==================
  Future<void> _saveSession() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (_mediaPath != null) {
      await _prefs!.setString(_kLastPath, _mediaPath!);
      await _prefs!.setInt(_kLastPosMs, _position.inMilliseconds);
    }
  }

  // ================== RECENTS ==================
  Future<void> _loadRecents() async {
    _prefs ??= await SharedPreferences.getInstance();
    _recents.clear();
    final raw = _prefs!.getString(_kRecents);
    if (raw != null && raw.isNotEmpty) {
      final List data = json.decode(raw) as List;
      _recents.addAll(data.cast<String>().where((p0) => p0 is String));
    }
    // filtre fichiers disparus
    _recents.removeWhere((path) => !File(path).existsSync());
    await _saveRecents();
    setState(() {});
  }

  Future<void> _saveRecents() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_kRecents, json.encode(_recents));
  }

  void _touchRecent(String path) {
    // place en tête, sans doublons, taille max
    _recents.remove(path);
    _recents.insert(0, path);
    if (_recents.length > _kMaxRecents) {
      _recents.removeRange(_kMaxRecents, _recents.length);
    }
    _saveRecents();
    setState(() {});
  }

  void _removeRecent(String path) {
    _recents.remove(path);
    _saveRecents();
    setState(() {});
  }
  void _showRecentsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        if (_recents.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              "Aucun récent pour l’instant.\nOuvre un fichier pour l’ajouter ici.",
              style: TextStyle(color: Colors.white70),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: ListView.separated(
            itemCount: _recents.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
            itemBuilder: (context, i) {
              final path = _recents[i];
              final name = p.basename(path);
              return ListTile(
                leading: const Icon(Icons.music_note, color: Colors.white70),
                title: Text(name, style: const TextStyle(color: Colors.white)),
                subtitle: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white38)),
                onTap: () {
                  Navigator.pop(ctx);
                  if (File(path).existsSync()) {
                    _openPath(path, autostart: false);
                  } else {
                    _removeRecent(path);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Fichier introuvable. Retiré des récents.')),
                    );
                  }
                },
                trailing: IconButton(
                  tooltip: 'Retirer des récents',
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () {
                    _removeRecent(path);
                    Navigator.pop(ctx);
                    _showRecentsSheet(); // rouvre pour refléter la MAJ
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }
  // ================== marqueurs : CRUD + persistence ==================
  String get _storageKey {
    if (_mediaPath == null) return 'markers::no_file';
    return 'markers::${p.normalize(_mediaPath!)}';
  }

  Future<void> _loadMarkersForPath() async {
    _markers.clear();
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      final List data = json.decode(raw) as List;
      _markers.addAll(data.map((e) => _Marker.fromJson(e as Map<String, dynamic>)));
      _markers.sort((a, b) => a.positionMs.compareTo(b.positionMs));
    }
    setState(() {});
  }

  Future<void> _saveMarkersForPath() async {
    _prefs ??= await SharedPreferences.getInstance();
    final jsonStr = json.encode(_markers.map((m) => m.toJson()).toList());
    await _prefs!.setString(_storageKey, jsonStr);
  }

  Future<void> _renameMarker(_Marker m) async {
    final controller = TextEditingController(text: m.label);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text('Renommer le marqueur', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Nom',
            hintStyle: TextStyle(color: Colors.white54),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.orangeAccent)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          TextButton(
            onPressed: () {
              setState(() => m.label = controller.text.trim().isEmpty ? m.label : controller.text.trim());
              _saveMarkersForPath();
              Navigator.pop(ctx);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _deleteMarker(_Marker m) {
    setState(() => _markers.removeWhere((e) => e.id == m.id));
    _saveMarkersForPath();
  }

  void _jumpToMarker(_Marker m) {
    _seek(Duration(milliseconds: m.positionMs));
  }

  // === ajout instantané (nom auto) ===
  void _addMarker() async {
    if (!_hasDuration) return;
    final nowMs = _position.inMilliseconds;

    final m = _Marker(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      positionMs: nowMs,
      label: 'M${_markers.length + 1}', // nom auto
    );

    setState(() {
      _markers.add(m);
      _markers.sort((a, b) => a.positionMs.compareTo(b.positionMs));
    });
    _saveMarkersForPath();
  }

  // ================== UI ==================
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final title = _mediaPath == null ? 'Backing Track' : p.basename(_mediaPath!);

    final durMsDouble = _hasDuration ? _duration.inMilliseconds.toDouble() : 1.0;
    final posMsDouble = _safeClampDouble(
      _position.inMilliseconds.toDouble(),
      0.0,
      _hasDuration ? durMsDouble : 1.0,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: _audio.playing ? 'Pause' : 'Lecture',
            onPressed: () async {
              if (_mediaPath == null) {
                await _pickFile();
                return;
              }
              if (_audio.playing) {
                await _audio.pause();
              } else {
                await _audio.play();
              }
              setState(() {});
              _saveSession();
            },
            icon: Icon(_audio.playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Historique',
            onPressed: _showRecentsSheet,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: 'Ouvrir…',
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open),
          ),
          if (_recents.isNotEmpty)
            IconButton(
              tooltip: 'Vider la liste des récents',
              onPressed: () {
                _recents.clear();
                _saveRecents();
                setState(() {});
              },
              icon: const Icon(Icons.history_toggle_off),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addMarker,
        icon: const Icon(Icons.add),
        label: const Text('Marqueur'),
        backgroundColor: _accent,
        foregroundColor: Colors.black,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // --------- récents ---------
            if (_recents.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Récents', style: TextStyle(color: _muted, fontSize: 12)),
                    const SizedBox(height: 6),
                    if (_recents.isEmpty)
                      Text("Aucun récent.\nOuvre un fichier pour l’ajouter ici, ou tape l’icône Historique.",
                          style: TextStyle(color: Colors.white38, fontSize: 12)),
                    if (_recents.isNotEmpty)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _recents.map((path) {
                            final name = p.basename(path);
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: InputChip(
                                label: Text(name),
                                avatar: const Icon(Icons.music_note, size: 18),
                                onPressed: () {
                                  if (File(path).existsSync()) {
                                    _openPath(path, autostart: false);
                                  } else {
                                    _removeRecent(path);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Fichier introuvable. Retiré des récents.')),
                                    );
                                  }
                                },
                                onDeleted: () => _removeRecent(path),
                                deleteIcon: const Icon(Icons.close),
                                backgroundColor: const Color(0xFF1A1A1A),
                                labelStyle: const TextStyle(color: Colors.white),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            // --------- timeline + slider + points ---------
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(_fmt(_position), style: TextStyle(color: _muted, fontSize: 12)),
                      const Spacer(),
                      Text(_fmt(_duration), style: TextStyle(color: _muted, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 6),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      final trackW = constraints.maxWidth;

                      return Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          // Slider (dessous)
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              activeTrackColor: _accent,
                              inactiveTrackColor: Colors.white24,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                              overlayShape: SliderComponentShape.noOverlay,
                            ),
                            child: Slider(
                              value: posMsDouble,
                              min: 0.0,
                              max: durMsDouble,
                              onChanged: !_hasDuration
                                  ? null
                                  : (v) => setState(() => _position = Duration(milliseconds: v.round())),
                              onChangeEnd: !_hasDuration
                                  ? null
                                  : (v) {
                                _seek(Duration(milliseconds: v.round()));
                                _saveSession();
                              },
                            ),
                          ),

                          // Points cliquables (au-dessus)
                          if (_markers.isNotEmpty && _hasDuration)
                            ..._markers.map((m) {
                              final x = _safeClampDouble((m.positionMs / durMsDouble) * trackW, 0.0, trackW);
                              const dot = 10.0;
                              return Positioned(
                                left: x - dot / 2,
                                top: 14, // position verticale du point au niveau du track
                                child: GestureDetector(
                                  onTap: () {
                                    _jumpToMarker(m);
                                    _saveSession();
                                  },
                                  onLongPress: () => _renameMarker(m),
                                  child: Container(
                                    width: dot,
                                    height: dot,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(color: _accent, width: 2),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: Colors.white12),

            // --------- liste des marqueurs ---------
            Expanded(
              child: _markers.isEmpty
                  ? Center(
                child: Text(
                  _mediaPath == null
                      ? 'Ouvre un backing track pour commencer.'
                      : 'Aucun marqueur. Appuie sur “Marqueur” pendant la lecture.',
                  style: TextStyle(color: _muted),
                  textAlign: TextAlign.center,
                ),
              )
                  : ListView.separated(
                itemCount: _markers.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                itemBuilder: (context, i) {
                  final m = _markers[i];
                  final d = Duration(milliseconds: m.positionMs);
                  return ListTile(
                    dense: false,
                    title: Text(
                      m.label,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(_fmt(d), style: TextStyle(color: _muted)),
                    onTap: () {
                      _jumpToMarker(m);
                      _saveSession();
                    },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Renommer',
                          onPressed: () => _renameMarker(m),
                          icon: const Icon(Icons.edit, color: Colors.white70),
                        ),
                        IconButton(
                          tooltip: 'Supprimer',
                          onPressed: () => _deleteMarker(m),
                          icon: const Icon(Icons.delete_outline, color: Colors.white70),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================== modèle de marqueur ==================
class _Marker {
  final String id;
  final int positionMs;
  String label;

  _Marker({
    required this.id,
    required this.positionMs,
    required this.label,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'pos': positionMs,
    'label': label,
  };

  static _Marker fromJson(Map<String, dynamic> m) => _Marker(
    id: m['id'] as String,
    positionMs: m['pos'] as int,
    label: m['label'] as String,
  );
}