import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

class YoutubeScreen extends StatefulWidget {
  const YoutubeScreen({super.key});
  @override
  State<YoutubeScreen> createState() => _YoutubeScreenState();
}

class _YoutubeScreenState extends State<YoutubeScreen> {
  // ---------- UI state ----------
  final TextEditingController _urlCtrl = TextEditingController();
  final List<String> _saved = [];
  String? _currentUrl;
  String? _currentId;

  // ---------- YouTube ----------
  YoutubePlayerController? _yt;

  // ---------- Markers ----------
  List<_Marker> _markers = [];
  int _autoName = 1;

  // ---------- Loop A/B ----------
  int? _loopAms; // millisecondes
  int? _loopBms;
  bool _loopOn = false;

  // ---------- Lifecycle ----------
  @override
  void initState() {
    super.initState();
    _restoreSavedList().then((_) => _restoreLast());
  }

  @override
  void dispose() {
    _yt?.removeListener(_ytListener);
    _yt?.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  // ---------- Persistence ----------
  Future<void> _restoreSavedList() async {
    final sp = await SharedPreferences.getInstance();
    _saved
      ..clear()
      ..addAll(sp.getStringList('yt_saved') ?? const []);
    setState(() {});
  }

  Future<void> _persistSavedList() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('yt_saved', _saved);
  }

  Future<void> _setLastUrl(String url) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('yt_last', url);
  }

  Future<void> _restoreLast() async {
    final sp = await SharedPreferences.getInstance();
    final url = sp.getString('yt_last');
    if (url != null && url.isNotEmpty) {
      final id = YoutubePlayer.convertUrlToId(url);
      if (id != null) {
        _loadVideo(url, id);
      }
    }
  }

  String _mkKey(String videoId) => 'yt_markers_$videoId';

  Future<void> _saveMarkers() async {
    if (_currentId == null) return;
    final sp = await SharedPreferences.getInstance();
    final payload = jsonEncode(_markers.map((m) => m.toJson()).toList());
    await sp.setString(_mkKey(_currentId!), payload);
  }

  Future<void> _restoreMarkers(String videoId) async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_mkKey(videoId));
    if (raw == null) {
      setState(() => _markers = []);
      return;
    }
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    setState(() {
      _markers = list.map((e) => _Marker.fromJson(e)).toList();
      final nums = _markers
          .map((m) => int.tryParse(m.name.replaceFirst(RegExp(r'^Mark '), '')))
          .whereType<int>()
          .toList();
      _autoName = (nums.isEmpty ? 0 : (nums.reduce((a, b) => a > b ? a : b))) + 1;
    });
  }

  // ---------- Player ----------
  void _ytListener() {
    if (!mounted || _yt == null) return;
    // Boucle A/B : si activée, et pos >= B - tolérance => seek A
    if (_loopOn && _loopAms != null && _loopBms != null && _loopAms! < _loopBms!) {
      final posMs = _yt!.value.position.inMilliseconds;
      if (posMs >= _loopBms! - 150) {
        _yt!.seekTo(Duration(milliseconds: _loopAms!));
      }
    }
    setState(() {}); // refresh UI (position, titre, etc.)
  }

  void _loadVideo(String url, String id) {
    _currentUrl = url;
    _currentId = id;

    if (_yt == null) {
      _yt = YoutubePlayerController(
        initialVideoId: id,
        flags: const YoutubePlayerFlags(
          autoPlay: false,
          mute: false,
          enableCaption: false,
          forceHD: false,
        ),
      )..addListener(_ytListener);
    } else {
      _yt!.load(id);
    }

    // reset loop quand on change de vidéo
    _loopAms = null;
    _loopBms = null;
    _loopOn = false;

    _setLastUrl(url);
    _restoreMarkers(id);
    setState(() {});
  }

  void _playFromField() {
    final url = _urlCtrl.text.trim();
    final id = YoutubePlayer.convertUrlToId(url);
    if (id == null) {
      _snack("URL YouTube invalide");
      return;
    }
    _loadVideo(url, id);
  }

  void _saveUrlShortcut() {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    if (!_saved.contains(url)) {
      setState(() => _saved.insert(0, url));
      _persistSavedList();
    }
    _setLastUrl(url);
    _urlCtrl.clear();
  }

  void _playShortcut(String url) {
    final id = YoutubePlayer.convertUrlToId(url);
    if (id != null) _loadVideo(url, id);
  }

  Future<void> _renameShortcut(int i) async {
    final ctrl = TextEditingController(text: _saved[i]);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Modifier l’URL"),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: "URL YouTube")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text("OK")),
        ],
      ),
    );
    if (res != null && res.isNotEmpty) {
      setState(() => _saved[i] = res);
      _persistSavedList();
    }
  }

  void _removeShortcut(int i) {
    setState(() => _saved.removeAt(i));
    _persistSavedList();
  }

  // ---------- Markers ----------
  void _addMarkerQuick() {
    if (_yt == null || _currentId == null) return;
    final pos = _yt!.value.position;
    final m = _Marker(
      id: UniqueKey().toString(),
      name: "Mark $_autoName",
      ms: pos.inMilliseconds.clamp(0, (_yt!.value.metaData.duration.inMilliseconds)),
    );
    _autoName++;
    setState(() => _markers.add(m));
    _saveMarkers();
  }

  Future<void> _renameMarker(_Marker m) async {
    final ctrl = TextEditingController(text: m.name);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Renommer le marqueur"),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: "Nom")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text("OK")),
        ],
      ),
    );
    if (res != null && res.isNotEmpty) {
      setState(() => m.name = res);
      _saveMarkers();
    }
  }

  void _deleteMarker(_Marker m) {
    setState(() => _markers.removeWhere((x) => x.id == m.id));
    _saveMarkers();
  }

  void _seekTo(int ms) {
    if (_yt == null) return;
    _yt!.seekTo(Duration(milliseconds: ms));
  }

  // ---------- Loop helpers ----------
  void _setLoopAFromCurrent() {
    if (_yt == null) return;
    final pos = _yt!.value.position.inMilliseconds;
    setState(() {
      _loopAms = pos;
      if (_loopBms != null && _loopBms! < _loopAms!) _loopBms = null; // garder A < B
    });
  }

  void _setLoopBFromCurrent() {
    if (_yt == null) return;
    final pos = _yt!.value.position.inMilliseconds;
    setState(() {
      _loopBms = pos;
      if (_loopAms != null && _loopAms! > _loopBms!) _loopAms = null;
    });
  }

  void _toggleLoop() {
    if (_loopAms == null || _loopBms == null || _loopAms! >= _loopBms!) {
      _snack("Définis d’abord A puis B (A < B)");
      return;
    }
    setState(() => _loopOn = !_loopOn);
  }

  void _clearLoop() {
    setState(() {
      _loopAms = null;
      _loopBms = null;
      _loopOn = false;
    });
  }

  // ---------- UI helpers ----------
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

  @override
  Widget build(BuildContext context) {
    final muted = Colors.white54;
    final pos = _yt?.value.position ?? Duration.zero;
    final dur = _yt?.value.metaData.duration ?? Duration.zero;
    final title = _yt?.value.metaData.title ?? "—";
    final durMs = dur.inMilliseconds.clamp(0, 24 * 3600 * 1000);

    // --- player widget ---
    final player = _yt == null
        ? const Center(child: Text("Aucune vidéo", style: TextStyle(color: Colors.white54)))
        : YoutubePlayer(
      controller: _yt!,
      showVideoProgressIndicator: true,
      progressIndicatorColor: Colors.redAccent,
    );

    // --- timeline with markers and loop overlay ---
    final timeline = SizedBox(
      height: 32,
      child: LayoutBuilder(
        builder: (ctx, cons) {
          final w = cons.maxWidth;
          final p = durMs == 0 ? 0.0 : pos.inMilliseconds / durMs;
          final hasLoop = (_loopAms != null && _loopBms != null && _loopAms! < _loopBms!);

          double loopLeft = 0, loopWidth = 0;
          if (hasLoop && durMs > 0) {
            final ax = (_loopAms! / durMs) * w;
            final bx = (_loopBms! / durMs) * w;
            loopLeft = ax.clamp(0.0, w);
            loopWidth = (bx - ax).clamp(0.0, w - loopLeft);
          }

          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              // fond
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              // overlay boucle A-B
              if (hasLoop)
                Positioned(
                  left: loopLeft,
                  width: loopWidth,
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              // barre de progression
              FractionallySizedBox(
                widthFactor: p.clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              // marqueurs (points cliquables)
              ..._markers.map((m) {
                final x = durMs == 0 ? 0.0 : (m.ms / durMs) * w;
                return Positioned(
                  left: (x - 4).clamp(0.0, w - 8),
                  child: GestureDetector(
                    onTap: () => _seekTo(m.ms),
                    onLongPress: () async {
                      // choisir A ou B depuis un marqueur
                      final choice = await showModalBottomSheet<String>(
                        context: context,
                        builder: (_) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(Icons.flag_outlined),
                                title: const Text("Définir A ici"),
                                onTap: () => Navigator.pop(context, 'A'),
                              ),
                              ListTile(
                                leading: const Icon(Icons.outlined_flag),
                                title: const Text("Définir B ici"),
                                onTap: () => Navigator.pop(context, 'B'),
                              ),
                            ],
                          ),
                        ),
                      );
                      if (choice == 'A') setState(() => _loopAms = m.ms);
                      if (choice == 'B') setState(() => _loopBms = m.ms);
                    },
                    child: Tooltip(
                      message: "${m.name} • ${_fmt(Duration(milliseconds: m.ms))}",
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                );
              }),
              // capteur de tap pour seek
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    if (durMs == 0) return;
                    final rel = d.localPosition.dx / w;
                    _seekTo((rel.clamp(0.0, 1.0) * durMs).round());
                  },
                ),
              ),
            ],
          );
        },
      ),
    );

    // --- barre de contrôles A/B ---
    final loopControls = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        children: [
          // boutons A / B
          ElevatedButton.icon(
            onPressed: _setLoopAFromCurrent,
            icon: const Icon(Icons.flag_outlined),
            label: const Text("Set A"),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _setLoopBFromCurrent,
            icon: const Icon(Icons.outlined_flag),
            label: const Text("Set B"),
          ),
          const SizedBox(width: 8),
          // toggle loop
          OutlinedButton.icon(
            onPressed: _toggleLoop,
            icon: Icon(_loopOn ? Icons.repeat_on : Icons.repeat),
            label: Text(_loopOn ? "Loop ON" : "Loop OFF"),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: "Effacer A/B",
            onPressed: _clearLoop,
            icon: const Icon(Icons.clear),
          ),
          const Spacer(),
          // affichage valeurs
          if (_loopAms != null)
            Chip(
              label: Text("A: ${_fmt(Duration(milliseconds: _loopAms!))}"),
              backgroundColor: Colors.white10,
            ),
          const SizedBox(width: 6),
          if (_loopBms != null)
            Chip(
              label: Text("B: ${_fmt(Duration(milliseconds: _loopBms!))}"),
              backgroundColor: Colors.white10,
            ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("YouTube"),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: "Ajouter un marqueur (instantané)",
            onPressed: _addMarkerQuick,
            icon: const Icon(Icons.add_location_alt_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          // barre URL
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: "Colle une URL YouTube…",
                      hintStyle: TextStyle(color: muted),
                      filled: true,
                      fillColor: const Color(0xFF1a1a1a),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade700),
                      ),
                    ),
                    onSubmitted: (_) => _playFromField(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: _playFromField, icon: const Icon(Icons.play_arrow, color: Colors.white)),
                IconButton(onPressed: _saveUrlShortcut, icon: const Icon(Icons.bookmark_add, color: Colors.white)),
              ],
            ),
          ),

          // player
          AspectRatio(aspectRatio: 16 / 9, child: Container(color: const Color(0xFF0f0f0f), child: player)),

          // titre + temps
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              Expanded(
                child: Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Text(_fmt(pos), style: TextStyle(color: muted)),
              const Text(" / "),
              Text(_fmt(dur), style: TextStyle(color: muted)),
            ]),
          ),

          // timeline + contrôles A/B
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: timeline),
          loopControls,

          // liste gauche/droite
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: _saved.isEmpty
                      ? Center(child: Text("Aucun lien enregistré", style: TextStyle(color: muted)))
                      : ListView.separated(
                    itemCount: _saved.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (ctx, i) {
                      final url = _saved[i];
                      return Dismissible(
                        key: ValueKey(url),
                        background: Container(color: Colors.red),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => _removeShortcut(i),
                        child: ListTile(
                          dense: true,
                          title: Text(url,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white)),
                          leading: const Icon(Icons.video_library, color: Colors.white70),
                          trailing: IconButton(
                            icon: const Icon(Icons.edit, color: Colors.white70),
                            onPressed: () => _renameShortcut(i),
                          ),
                          onTap: () => _playShortcut(url),
                        ),
                      );
                    },
                  ),
                ),
                const VerticalDivider(color: Colors.white12, width: 1),
                Expanded(
                  flex: 4,
                  child: _markers.isEmpty
                      ? Center(child: Text("Aucun marqueur", style: TextStyle(color: muted)))
                      : ListView.separated(
                    itemCount: _markers.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (ctx, i) {
                      final m = _markers[i];
                      return ListTile(
                        dense: true,
                        title: Text(m.name, style: const TextStyle(color: Colors.white)),
                        subtitle: Text(_fmt(Duration(milliseconds: m.ms)),
                            style: TextStyle(color: muted)),
                        leading: const Icon(Icons.place, color: Colors.orangeAccent),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: "Renommer",
                            icon: const Icon(Icons.edit, color: Colors.white70),
                            onPressed: () => _renameMarker(m),
                          ),
                          IconButton(
                            tooltip: "Supprimer",
                            icon: const Icon(Icons.delete_outline, color: Colors.white70),
                            onPressed: () => _deleteMarker(m),
                          ),
                        ]),
                        onTap: () => _seekTo(m.ms),
                      );
                    },
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

// ====== simple model ======
class _Marker {
  final String id;
  String name;
  int ms;
  _Marker({required this.id, required this.name, required this.ms});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'ms': ms};
  factory _Marker.fromJson(Map<String, dynamic> j) =>
      _Marker(id: j['id'] as String, name: j['name'] as String, ms: j['ms'] as int);
}

// Petit clamp sur int (pratique pour la timeline)
extension on int {
  int clamp(int min, int max) => this < min ? min : (this > max ? max : this);
}