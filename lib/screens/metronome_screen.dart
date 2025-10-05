import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key});
  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen> {
  int _bpm = 100;                 // 20..240
  int _beatsPerBar = 4;           // 3 ou 4
  bool _running = false;
  int _beatIndex = 0;             // 0..(beatsPerBar-1)
  Timer? _timer;

  // Tap-tempo
  final List<DateTime> _taps = [];

  Duration get _interval => Duration(milliseconds: (60000 / _bpm).round());

  void _start() {
    _timer?.cancel();
    _beatIndex = 0;
    _running = true;
    _timer = Timer.periodic(_interval, (_) => _tick());
    setState(() {});
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _beatIndex = 0;
    setState(() {});
  }

  Future<void> _tick() async {
    final accent = _beatIndex == 0;

    // 1) petit son système (alert > click) — parfois muet selon l’OS
    await SystemSound.play(SystemSoundType.alert);

    // 2) retour haptique (toujours perçu même si le son système est muet)
    if (accent) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.lightImpact();
    }

    setState(() {
      _beatIndex = (_beatIndex + 1) % _beatsPerBar;
    });
  }

  void _bpmMinus() {
    setState(() => _bpm = (_bpm - 1).clamp(20, 240));
    if (_running) _start(); // redémarre avec le nouvel intervalle
  }

  void _bpmPlus() {
    setState(() => _bpm = (_bpm + 1).clamp(20, 240));
    if (_running) _start();
  }

  void _tapTempo() {
    final now = DateTime.now();
    _taps.add(now);
    // garde seulement les 6 derniers taps
    while (_taps.length > 6) _taps.removeAt(0);
    if (_taps.length >= 2) {
      // moyenne des intervalles
      final intervals = <int>[];
      for (var i = 1; i < _taps.length; i++) {
        intervals.add(_taps[i].difference(_taps[i - 1]).inMilliseconds);
      }
      final avgMs = intervals.reduce((a, b) => a + b) / intervals.length;
      final bpm = (60000 / avgMs).round().clamp(20, 240);
      setState(() => _bpm = bpm);
      if (_running) _start();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = _beatIndex == 0;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Métronome'),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // cercle pulsant
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: accent ? 160 : 140,
              height: accent ? 160 : 140,
              decoration: BoxDecoration(
                color: accent ? Colors.orangeAccent : Colors.white12,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
              alignment: Alignment.center,
              child: Text(
                '${_beatIndex + 1}',
                style: const TextStyle(color: Colors.white70, fontSize: 28),
              ),
            ),
            const SizedBox(height: 24),

            // BPM + boutons
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MiniBtn(label: '–', onTap: _bpmMinus),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('$_bpm BPM',
                      style: const TextStyle(color: Colors.white, fontSize: 28)),
                ),
                _MiniBtn(label: '+', onTap: _bpmPlus),
              ],
            ),
            const SizedBox(height: 12),

            // Mesure 3/4 ou 4/4
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Choice(
                  label: '3/4',
                  selected: _beatsPerBar == 3,
                  onTap: () {
                    setState(() => _beatsPerBar = 3);
                    if (_running) _start();
                  },
                ),
                const SizedBox(width: 12),
                _Choice(
                  label: '4/4',
                  selected: _beatsPerBar == 4,
                  onTap: () {
                    setState(() => _beatsPerBar = 4);
                    if (_running) _start();
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Start / Stop
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MainBtn(
                  label: _running ? 'Stop' : 'Start',
                  onTap: _running ? _stop : _start,
                ),
                const SizedBox(width: 16),
                _MainBtn(label: 'Tap', onTap: _tapTempo),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// UI helpers — petits boutons
class _MiniBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MiniBtn({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 20)),
      ),
    );
  }
}

class _MainBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _MainBtn({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 18)),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Choice({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.orangeAccent : Colors.white10,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white,
              fontWeight: FontWeight.w600,
            )),
      ),
    );
  }
}