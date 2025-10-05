import 'dart:convert';
import 'dart:ui' show FontFeature;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/playback_service.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  // ================== ÉTAT ==================
  bool _isPlaying = false; // visuel du bouton (mock léger)
  double _posSec = 0.0;    // position courante (s)
  double _durSec = 0.0;    // durée totale (s)

  // Vitesse
  double _speed = 1.0;
  static const List<double> _speedPresets = [0.50, 0.75, 1.00, 1.25, 1.50];

  // IN/OUT en cours (avant validation)
  double? _inSec;
  double? _outSec;

  // Boucles persistées (modèle riche)
  final List<_Loop> _loops = <_Loop>[];
  int _activeLoopIndex = -1; // -1 = aucune active

  // Palette couleurs pour nouvelles boucles
  final List<Color> _palette = const [
    Color(0xFFEF4444), // rouge
    Color(0xFF22D3EE), // cyan
    Color(0xFFF59E0B), // orange
    Color(0xFFA78BFA), // violet
    Color(0xFF34D399), // vert
  ];
  int _paletteIndex = 0;
  Color _nextColor() {
    final c = _palette[_paletteIndex % _palette.length];
    _paletteIndex++;
    return c;
  }

  // SharedPreferences (sync avec PlayerScreen)
  SharedPreferences? _prefs;
  static const _kPrefSpeed = 'last.speed';
  static const _kPrefA = 'last.a';                // en millisecondes
  static const _kPrefB = 'last.b';                // en millisecondes
  static const _kPrefLoop = 'last.loop';          // boucle activée
  static const _kPrefActiveLoop = 'last.activeLoopIndex';
  static const _kPrefLoops = 'loops.json';        // stockage JSON des boucles

  // Abonnements au service
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription? _loopServiceSub;

  // Couleurs UI
  static const _accent = Color(0xFFFF9500);
  final Color _panel  = Colors.white.withOpacity(0.05);
  final Color _border = Colors.white24;
  int _indexOfLoopNear(double aSec, double bSec, {double eps = 0.0005}) {
    for (var i = 0; i < _loops.length; i++) {
      final l = _loops[i];
      if ((l.aSec - aSec).abs() < eps && (l.bSec - bSec).abs() < eps) {
        return i;
      }
    }
    return -1;
  }


  // ================== LIFECYCLE ==================
  @override
  void initState() {
    super.initState();
    _initPrefs();

    // Valeurs actuelles si un média joue déjà
    final d = PlaybackService.I.duration;
    final p = PlaybackService.I.position;
    _durSec = d.inMilliseconds / 1000.0;
    _posSec = p.inMilliseconds / 1000.0;

    // Abonnements aux flux (durée / position)
    _durSub = PlaybackService.I.durationStream.listen((d) {
      setState(() => _durSec = d.inMilliseconds / 1000.0);
    });
    _posSub = PlaybackService.I.positionStream.listen((p) {
      setState(() => _posSec = p.inMilliseconds / 1000.0);
    });

    // Boucles créées côté Player → refléter dans l’Editor sans dupliquer
    _loopServiceSub = PlaybackService.I.loopStream.listen((evt) async {
      if (evt == null || evt.enabled != true) return;
      final a = evt.a; // Duration?
      final b = evt.b; // Duration?
      if (a == null || b == null) return;

      final aSec = a.inMilliseconds / 1000.0;
      final bSec = b.inMilliseconds / 1000.0;
      if (bSec <= aSec) return;

      // 1) Chercher si cette boucle existe déjà
      final existingIdx = _indexOfLoopNear(aSec, bSec);
      if (existingIdx != -1) {
        // → Elle existe : on l’active seulement
        setState(() => _activeLoopIndex = existingIdx);
        await _saveLoops();
        return;
      }

      // 2) Sinon on l’ajoute
      final color = _nextColor();
      final newLoop = _Loop(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        aSec: aSec,
        bSec: bSec,
        name: 'Boucle ${_loops.length + 1}',
        colorHex: color.value,
      );

      setState(() {
        _loops.add(newLoop);
        _activeLoopIndex = _loops.length - 1;
      });
      await _saveLoops();
    });
  }
  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _loopServiceSub?.cancel();
    super.dispose();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {
      _speed = _prefs?.getDouble(_kPrefSpeed) ?? 1.0;
    });

    // Charger boucles persistées
    final raw = _prefs?.getString(_kPrefLoops);
    if (raw != null && raw.isNotEmpty) {
      final List data = json.decode(raw) as List;
      setState(() {
        _loops
          ..clear()
          ..addAll(data.map((e) => _Loop.fromJson(e as Map<String, dynamic>)));
        _activeLoopIndex = _prefs?.getInt(_kPrefActiveLoop) ?? -1;
      });
    }
  }

  Future<void> _saveLoops() async {
    _prefs ??= await SharedPreferences.getInstance();
    final data = json.encode(_loops.map((e) => e.toJson()).toList());
    await _prefs!.setString(_kPrefLoops, data);
    await _prefs!.setInt(_kPrefActiveLoop, _activeLoopIndex);
  }

  // --------- helper : envoyer la boucle active au Player via le service ----------
  void _sendLoopToPlayer({required double aSec, required double bSec, bool enabled = true}) {
    PlaybackService.I.updateLoop(
      a: Duration(milliseconds: (aSec * 1000).round()),
      b: Duration(milliseconds: (bSec * 1000).round()),
      enabled: enabled,
    );
  }

  // ================== ACTIONS IN/OUT & PERSISTANCE ==================
  void _markIn() {
    setState(() {
      _inSec = _posSec.clamp(0.0, _durSec);
      if (_outSec != null && _outSec! <= _inSec!) _outSec = null;
    });
    _toast('IN à ${_fmt(_inSec!.round())}');
  }

  Future<void> _markOut() async {
    setState(() {
      _outSec = _posSec.clamp(0.0, _durSec);
    });

    if (_inSec != null && _outSec! > _inSec!) {
      final color = _nextColor();
      final name = 'Boucle ${_loops.length + 1}';
      final newLoop = _Loop(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        aSec: _inSec!,
        bSec: _outSec!,
        name: name,
        colorHex: color.value,
      );

      setState(() {
        _loops.add(newLoop);
        _activeLoopIndex = _loops.length - 1;
      });
      _toast('Boucle ${_fmt(_inSec!.round())} → ${_fmt(_outSec!.round())} enregistrée');

      // → envoie au Player pour boucler tout de suite
      _sendLoopToPlayer(aSec: _inSec!, bSec: _outSec!, enabled: true);

      // Persiste pour le Player & la liste
      await _persistLoopToPlayer(aSec: _inSec!, bSec: _outSec!, index: _activeLoopIndex);
      await _saveLoops();

      // Reset IN/OUT en cours
      setState(() { _inSec = null; _outSec = null; });
    }
  }

  void _clearInOut() {
    setState(() { _inSec = null; _outSec = null; });
    _toast('IN/OUT annulés');
  }
  int _indexOfLoop(double aSec, double bSec) {
    for (int i = 0; i < _loops.length; i++) {
      final l = _loops[i];
      if ((l.aSec - aSec).abs() < 0.0005 && (l.bSec - bSec).abs() < 0.0005) {
        return i; // trouvé
      }
    }
    return -1; // pas trouvé
  }
  Future<void> _activateLoop(int index) async {
    if (index < 0 || index >= _loops.length) return;
    final l = _loops[index];
    setState(() {
      _activeLoopIndex = index;
      _posSec = l.aSec; // feedback visuel
    });

    // → active la boucle dans le Player
    _sendLoopToPlayer(aSec: l.aSec, bSec: l.bSec, enabled: true);

    await _persistLoopToPlayer(aSec: l.aSec, bSec: l.bSec, index: index);
    await _saveLoops();
    _toast('Boucle “${l.name}” activée');

    // On se place vraiment dans le média
    await PlaybackService.I.seekSeconds(l.aSec);
  }

  Future<void> _renameLoop(int index) async {
    if (index < 0 || index >= _loops.length) return;
    final l = _loops[index];
    final controller = TextEditingController(text: l.name);

    final newName = await showDialog<String?>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.black87,
        title: const Text('Renommer la boucle', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Nom',
            hintStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('OK')),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty) {
      setState(() => _loops[index].name = newName);
      await _saveLoops();
    }
  }

  Future<void> _deleteLoop(int index) async {
    if (index < 0 || index >= _loops.length) return;
    final removedActive = (index == _activeLoopIndex);
    setState(() => _loops.removeAt(index));
    if (removedActive) {
      _activeLoopIndex = -1;
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setBool(_kPrefLoop, false); // coupe la boucle côté Player
    } else if (index < _activeLoopIndex) {
      _activeLoopIndex -= 1;
    }
    await _saveLoops();
  }

  Future<void> _persistLoopToPlayer({
    required double aSec,
    required double bSec,
    required int index,
  }) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setInt(_kPrefA, (aSec * 1000.0).round());
    await _prefs!.setInt(_kPrefB, (bSec * 1000.0).round());
    await _prefs!.setBool(_kPrefLoop, true);
    await _prefs!.setInt(_kPrefActiveLoop, index);
  }

  // ================== SPEED (feuille + persistance) ==================
  Future<void> _applySpeed(double v) async {
    v = v.clamp(0.50, 1.50);
    setState(() => _speed = double.parse(v.toStringAsFixed(2)));
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setDouble(_kPrefSpeed, _speed);
  }

  void _showSpeedSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        double localSpeed = _speed;
        return StatefulBuilder(
          builder: (context, setLocal) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Playback speed',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3.0,
                      activeTrackColor: Colors.orangeAccent,
                      inactiveTrackColor: Colors.white24,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0),
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: localSpeed,
                      min: 0.5,
                      max: 1.5,
                      divisions: 20,
                      label: '${localSpeed.toStringAsFixed(2)}×',
                      onChanged: (v) => setLocal(() => localSpeed = double.parse(v.toStringAsFixed(2))),
                      onChangeEnd: (v) => _applySpeed(v),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: _speedPresets.map((v) {
                      final active = (v == localSpeed);
                      return _speedPill(
                        text: '${v.toStringAsFixed(2)}×',
                        active: active,
                        onTap: () {
                          _applySpeed(v);
                          setLocal(() => localSpeed = v);
                          Navigator.of(context).maybePop();
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ================== BUILD ==================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            children: [
              const SizedBox(height: 8),

              // ===== IN / OUT + Compteurs + Speed =====
              _panelBox(
                child: Row(
                  children: [
                    _smallBtn('IN', _markIn),
                    const Spacer(),
                    _inlineCounter('Position', _fmt(_posSec.round())),
                    const SizedBox(width: 12),
                    _inlineCounter('Durée', _fmt(_durSec.round())),
                    const Spacer(),
                    _smallBtn('OUT', _markOut),
                    const SizedBox(width: 10),
                    _ghostChip(label: 'Speed ${_speed.toStringAsFixed(2)}×', onTap: _showSpeedSheet),
                  ],
                ),
              ),

              // ===== Badges IN/OUT en cours =====
              if (_inSec != null || _outSec != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_inSec != null)
                        _badge('IN', _fmt(_inSec!.round()), const Color(0xFF22D3EE)),
                      if (_inSec != null && _outSec != null) const SizedBox(width: 10),
                      if (_outSec != null)
                        _badge('OUT', _fmt(_outSec!.round()), const Color(0xFFEF4444)),
                      const SizedBox(width: 10),
                      TextButton.icon(
                        onPressed: _clearInOut,
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('Annuler'),
                      ),
                    ],
                  ),
                ),

              // ===== Molette horizontale + Transport =====
              _panelBox(
                child: Column(
                  children: [
                    _jogStripThin(
                      onLeft:  () {
                        final t = (_posSec - 0.4).clamp(0.0, _durSec);
                        PlaybackService.I.seekSeconds(t);
                      },
                      onRight: () {
                        final t = (_posSec + 0.4).clamp(0.0, _durSec);
                        PlaybackService.I.seekSeconds(t);
                      },
                      onDragDelta: (dx) {
                        final delta = dx * 0.02; // sensibilité fine
                        final t = (_posSec + delta).clamp(0.0, _durSec);
                        PlaybackService.I.seekSeconds(t);
                      },
                    ),

                    const SizedBox(height: 8),

                    // Transport: -1s / Play-Pause / +1s
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _transportBtn(
                          icon: Icons.replay_10,
                          onTap: () {
                            final t = (_posSec - 1.0).clamp(0.0, _durSec);
                            PlaybackService.I.seekSeconds(t);
                          },
                        ),
                        const SizedBox(width: 14),
                        _transportBtn(
                          icon: _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                          big: true,
                          onTap: () async {
                            setState(() => _isPlaying = !_isPlaying);
                            await PlaybackService.I.playPause();
                          },
                        ),
                        const SizedBox(width: 14),
                        _transportBtn(
                          icon: Icons.forward_10,
                          onTap: () {
                            final t = (_posSec + 1.0).clamp(0.0, _durSec);
                            PlaybackService.I.seekSeconds(t);
                          },
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),
                    Text(
                      'Faites glisser pour régler précisément la position',
                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
                    ),
                  ],
                ),
              ),

              // ===== Mes boucles =====
              _panelBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Text('Mes boucles',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        if (_inSec != null && _outSec != null && _outSec! > _inSec!)
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orangeAccent,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            onPressed: _markOut, // réutilise l’enregistrement
                            icon: const Icon(Icons.save),
                            label: const Text('Enregistrer'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    if (_loops.isEmpty)
                      const Text('Aucune boucle enregistrée',
                          style: TextStyle(color: Colors.white54))
                    else
                      SizedBox(
                        height: 132,
                        child: ListView.separated(
                          itemCount: _loops.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, i) => _loopTile(i, _loops[i], i == _activeLoopIndex),
                        ),
                      ),
                  ],
                ),
              ),

              // ===== espace central extensible =====
              const Expanded(child: SizedBox()),

              // ===== Timeline (avec boucles) =====
              _panelBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _timelineWithMarkers(
                      positionSec: _posSec,
                      durationSec: _durSec,
                      loops: _loops.map((l) => _LoopSpan(
                        startSec: l.aSec,
                        endSec: l.bSec,
                        color: l.color,
                      )).toList(),
                      onSeek:     (v) => PlaybackService.I.seekSeconds(v),
                      onSeekEnd:  (v) => PlaybackService.I.seekSeconds(v),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(_posSec.round()),
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        Text(_fmt(_durSec.round()),
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ================== LOOP TILE (affichage d’une boucle) ==================
  Widget _loopTile(int index, _Loop l, bool active) {
    return InkWell(
      onTap: () => _activateLoop(index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: active ? Colors.white.withOpacity(0.08)
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? Colors.orangeAccent : Colors.white24,
          ),
        ),
        child: Row(
          children: [
            // pastille couleur
            Container(
              width: 14, height: 14,
              decoration: BoxDecoration(
                color: l.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1),
              ),
            ),
            const SizedBox(width: 10),

            // nom + temps
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('${_fmt(l.aSec.round())} → ${_fmt(l.bSec.round())}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),

            // actions
            IconButton(
              tooltip: 'Renommer',
              icon: const Icon(Icons.edit, size: 20, color: Colors.white70),
              onPressed: () => _renameLoop(index),
            ),
            IconButton(
              tooltip: 'Supprimer',
              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.white70),
              onPressed: () => _deleteLoop(index),
            ),
          ],
        ),
      ),
    );
  }

  // ================== UI HELPERS ==================
  Widget _panelBox({required Widget child}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: child,
    );
  }

  Widget _speedPill({
    required String text,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? Colors.orangeAccent : Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? Colors.orangeAccent : Colors.white24,
            width: 1.4,
          ),
          boxShadow: active
              ? const [BoxShadow(blurRadius: 8, color: Colors.black26)]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active) ...[
              const Icon(Icons.check, size: 16, color: Colors.black),
              const SizedBox(width: 6),
            ],
            Text(
              text,
              style: TextStyle(
                color: active ? Colors.black : Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallBtn(String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: _accent,
        side: const BorderSide(color: _accent, width: 1.4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: const Size(56, 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3),
      ),
      child: Text(label),
    );
  }

  Widget _inlineCounter(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white, fontSize: 13, fontWeight: FontWeight.w400,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _badge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Text(value, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _ghostChip({required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _transportBtn({
    required IconData icon,
    required VoidCallback onTap,
    bool big = false,
  }) {
    return InkResponse(
      radius: big ? 28 : 24,
      onTap: onTap,
      child: Icon(icon, size: big ? 44 : 28, color: Colors.white),
    );
  }

  // Molette horizontale fine
  Widget _jogStripThin({
    required VoidCallback onLeft,
    required VoidCallback onRight,
    required ValueChanged<double> onDragDelta,
  }) {
    return Container(
      height: 46.0,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDragDelta(d.delta.dx),
        onDoubleTap: onRight,
        onLongPress: onLeft,
        child: Stack(
          children: [
            CustomPaint(
              painter: _StripTickPainter(color: Colors.white38, ticks: 40),
              size: Size.infinite,
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Icon(Icons.chevron_left, color: Colors.white70),
            ),
            const Align(
              alignment: Alignment.centerRight,
              child: Icon(Icons.chevron_right, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Widget _timelineWithMarkers({
    required double positionSec,
    required double durationSec,
    required List<_LoopSpan> loops,
    required ValueChanged<double> onSeek,
    required ValueChanged<double> onSeekEnd,
  }) {
    final double pos = positionSec.clamp(0.0, durationSec).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _LoopSegmentsPainter(
                    loops: loops,
                    durationSec: durationSec,
                    accentHeight: 6.0,
                  ),
                ),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4.0,
                activeTrackColor: _accent,
                inactiveTrackColor: Colors.white24,
                overlayShape: SliderComponentShape.noOverlay,
                thumbColor: _accent,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.0),
              ),
              child: Slider(
                min: 0.0,
                max: durationSec <= 0.0 ? 1.0 : durationSec,
                value: pos,
                onChanged: (double v) => onSeek(v),
                onChangeEnd: (double v) => onSeekEnd(v),
              ),
            ),
          ],
        );
      },
    );
  }

  // ================== UTILS ==================
  String _fmt(int totalSec) {
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _toast(String msg) {
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 700)),
    );
  }
} // <- fin _EditorScreenState

// ================== PAINTERS ==================
class _StripTickPainter extends CustomPainter {
  final Color color;
  final int ticks;
  _StripTickPainter({required this.color, this.ticks = 20});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 1.0;
    final step = size.width / ticks;
    for (var i = 0; i <= ticks; i++) {
      final double x = i * step;
      final double h = (i % 5 == 0) ? size.height * 0.58 : size.height * 0.32;
      canvas.drawLine(Offset(x, size.height - h), Offset(x, size.height - 4.0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LoopSegmentsPainter extends CustomPainter {
  final List<_LoopSpan> loops;
  final double durationSec;
  final double accentHeight;

  _LoopSegmentsPainter({
    required this.loops,
    required this.durationSec,
    this.accentHeight = 6.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (durationSec <= 0.0) return;

    for (final span in loops) {
      final double start = (span.startSec.clamp(0.0, durationSec)).toDouble() / durationSec;
      final double end   = (span.endSec.clamp(0.0, durationSec)).toDouble() / durationSec;
      if (end <= start) continue;

      final double left  = start * size.width;
      final double right = end   * size.width;
      final Rect rect = Rect.fromLTWH(
        left,
        (size.height - accentHeight) / 2.0,
        (right - left),
        accentHeight,
      );

      final paint = Paint()..color = span.color.withOpacity(0.55);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3.0));
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LoopSegmentsPainter old) =>
      loops != old.loops || durationSec != old.durationSec || accentHeight != old.accentHeight;
}

// ================== MODELS ==================
class _LoopSpan {
  final double startSec;
  final double endSec;
  final Color color;
  const _LoopSpan({required this.startSec, required this.endSec, required this.color});
}

class _Loop {
  final String id;
  double aSec;
  double bSec;
  String name;
  int colorHex; // ARGB

  _Loop({
    required this.id,
    required this.aSec,
    required this.bSec,
    required this.name,
    required this.colorHex,
  });

  Color get color => Color(colorHex);

  Map<String, dynamic> toJson() => {
    'id': id,
    'a': aSec,
    'b': bSec,
    'name': name,
    'color': colorHex,
  };

  static _Loop fromJson(Map<String, dynamic> m) => _Loop(
    id: m['id'] as String,
    aSec: (m['a'] as num).toDouble(),
    bSec: (m['b'] as num).toDouble(),
    name: m['name'] as String,
    colorHex: m['color'] as int,
  );
}