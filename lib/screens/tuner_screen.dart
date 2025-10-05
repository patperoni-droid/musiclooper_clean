// lib/screens/tuner_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';
import 'dart:math' as math;

class TunerScreen extends StatefulWidget {
  const TunerScreen({super.key});
  @override
  TunerScreenState createState() => TunerScreenState(); // ← sans underscore
}
class TunerScreenState extends State<TunerScreen> with WidgetsBindingObserver {
  // --- Micro / capture
  final FlutterAudioCapture _cap = FlutterAudioCapture();
  bool _capInited = false;   // devient true après init()
  bool _running = false;     // capture en cours

  // --- Mesures affichées
  double _freq = 0.0;        // Hz
  double _cents = 0.0;       // -50..+50
  String _note = '—';

  // --- Réglages capture (robustes)
  static const int _sr = 48000;       // 48000 est souvent mieux supporté
  static const int _bufferSize = 8192; // plus gros buffer = démarre plus souvent

  @override
  void initState() {
    super.initState();
    _initCapture(); // prépare le plugin

    // Lance le micro automatiquement après le 1er build
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoStartMic());
  }
  Future<void> stopMic() async {
    if (_running) {
      try { await _cap.stop(); } catch (_) {}
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> autoStartMicIfAllowed() async {
    if (_running) return;
    final st = await Permission.microphone.request();
    if (!st.isGranted) return;
    // réutilise ton _toggleMic() (il démarre la capture)
    await _toggleMic();
  }
  Future<void> _initCapture() async {
    try {
      await _cap.init();  // OBLIGATOIRE avant start()
      _capInited = true;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('init error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Init micro impossible: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    if (_running) {
      _cap.stop().catchError((_) {});
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  Future<void> _autoStartMic() async {
    // Demande la permission si nécessaire
    final st = await Permission.microphone.request();

    if (!st.isGranted) {
      // si refusée, on laisse le bouton manuel
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Autorise le micro pour démarrer automatiquement')),
        );
      }
      return;
    }

    // Démarre si pas déjà en route
    if (!_running) {
      await _toggleMic(); // utilise ta fonction existante
    }
  }
  // ---- Bouton démarrer/arrêter
  Future<void> _toggleMic() async {
    // Si ça tourne déjà, on arrête
    if (_running) {
      try {
        await _cap.stop();
      } catch (e) {
        debugPrint('stop error: $e');
      }
      if (mounted) setState(() => _running = false);
      return;
    }

    // Demander la permission micro
    final st = await Permission.microphone.request();
    if (!st.isGranted) {
      if (mounted) {
        final action = st.isPermanentlyDenied
            ? SnackBarAction(label: 'Ouvrir Réglages', onPressed: openAppSettings)
            : null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: const Text('Micro refusé'), action: action),
        );
      }
      return;
    }

    // S’assurer que le plugin est prêt
    if (!_capInited) {
      await _initCapture();
      if (!_capInited) return;
    }

    // >>> Appel avec 2 ARGUMENTS POSITIONNELS <<<
    try {
      await _cap.start(
        _onData, // 1er argument positionnel: listener
            (Object e) { // 2e argument positionnel: onError
          debugPrint('audio error: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Erreur audio: $e')),
            );
          }
        },
        sampleRate: _sr,        // ensuite les options nommées
        bufferSize: _bufferSize,
      );
      if (mounted) setState(() => _running = true);
    } catch (e) {
      debugPrint('start error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Impossible de démarrer le micro: $e')),
        );
      }
    }
  }
  // ---- Callback audio : conversion vers Float32 + pitch
    void _onData(dynamic data) {
      try {
        final Float32List x = _toFloat32(data);
        if (x.isEmpty) return;

        final f = _detectPitchHz(x, _sr);
        if (f < 20 || f > 2000) return;

        final exactMidi = 69 + 12 * (math.log(f / 440) / math.ln2);
        final nearest   = exactMidi.round();
        final cents     = (exactMidi - nearest) * 100.0;

        if (!mounted) return;
        setState(() {
          _freq  = f;
          _cents = cents.clamp(-50.0, 50.0);
          _note  = _midiName(nearest);
        });
      } catch (e) {
        debugPrint('onData parse error: $e');
      }
    }

  // Convertit Float32List / Uint8List / ByteData -> Float32List [-1..1]
  Float32List _toFloat32(dynamic data) {
    if (data is Float32List) return data;
    if (data is Uint8List) {
      final len = data.length ~/ 2;
      final out = Float32List(len);
      final bd = ByteData.sublistView(data);
      for (int i = 0; i < len; i++) {
        out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      return out;
    }
    if (data is ByteData) {
      final len = data.lengthInBytes ~/ 2;
      final out = Float32List(len);
      for (int i = 0; i < len; i++) {
        out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
      }
      return out;
    }
    return Float32List(0);
  }

  // ---- Détection de pitch : auto-corrélation fenêtrée + interpolation
  double _detectPitchHz(Float32List input, int sr) {
    if (input.isEmpty) return 0;
    final n = math.min(input.length, 4096);
    final x = Float32List(n);
    for (int i = 0; i < n; i++) { x[i] = input[i]; }

    // retire DC
    double mean = 0;
    for (final v in x) { mean += v; }
    mean /= n;
    for (int i = 0; i < n; i++) { x[i] -= mean; }

    // fenêtre Hann
    for (int i = 0; i < n; i++) {
      final w = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
      x[i] *= w;
    }

    final minLag = (sr / 1000).floor(); // 1000 Hz
    final maxLag = (sr / 50).floor();   // 50 Hz
    double best = -1e9;
    int bestLag = 0;

    // corrélation simple (stride 2 = plus rapide, assez précis)
    for (int lag = minLag; lag <= maxLag; lag++) {
      double s = 0;
      final limit = n - lag;
      for (int i = 0; i < limit; i += 2) {
        s += x[i] * x[i + lag];
      }
      if (s > best) { best = s; bestLag = lag; }
    }
    if (bestLag == 0) return 0;

    // interpolation parabolique pour raffiner
    double y1 = 0, y2 = 0, y3 = 0;
    for (int i = 0; i < n - (bestLag - 1); i++) y1 += x[i] * x[i + bestLag - 1];
    for (int i = 0; i < n -  bestLag     ; i++) y2 += x[i] * x[i + bestLag     ];
    for (int i = 0; i < n - (bestLag + 1); i++) y3 += x[i] * x[i + bestLag + 1];

    final denom = 2 * (y1 - 2*y2 + y3);
    if (denom.abs() > 1e-9) {
      final delta = (y1 - y3) / denom; // -0.5..+0.5
      final refined = bestLag + delta;
      return sr / refined;
    }
    return sr / bestLag;
  }

  // ---- Utils notes
  static const _names = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
  String _midiName(int midi) {
    final name = _names[midi % 12];
    final octave = (midi ~/ 12) - 1;
    return '$name$octave';
  }

  // ---- UI
  @override
  Widget build(BuildContext context) {
    final angle = (_cents / 50.0) * (math.pi / 6); // +/- 30°
    final inTune = _cents.abs() < 5;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Accordeur'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(
              _running ? Icons.mic : Icons.mic_off,
              color: _running ? Colors.cyanAccent : Colors.white38,
            ),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Jauge + aiguille
              SizedBox(
                width: 240, height: 130,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    Positioned.fill(child: CustomPaint(painter: _GaugePainter())),
                    Transform.rotate(
                      angle: angle,
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: 2, height: 95,
                        color: inTune ? Colors.cyanAccent : Colors.orangeAccent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _note,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                ),
              ),

              Text(
                'Init: ${_capInited ? "OK" : "non"}  •  Capture: ${_running ? "ON" : "OFF"}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 8),
              const Text(
                'Astuce: préférez un vrai téléphone (micro de l’émulateur limité).',
                style: TextStyle(color: Colors.white24, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final w = size.width, h = size.height;
    final rect = Rect.fromLTWH(10, 10, w - 20, h - 20);
    final sweep = math.pi / 3; // 60°
    final start = math.pi + (math.pi/2 - sweep/2);

    paint.color = Colors.white24;
    canvas.drawArc(rect, start, sweep, false, paint);

    paint.color = Colors.white38;
    final cx = w / 2;
    canvas.drawLine(Offset(cx, h - 10), Offset(cx, 18), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}