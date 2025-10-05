// lib/core/playback_service.dart
import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

/// Évènement de boucle (A/B) partagé entre Player et Editor.
class LoopEvent {
  final Duration a;
  final Duration b;
  final bool enabled;
  const LoopEvent({required this.a, required this.b, required this.enabled});
}

class PlaybackService {
  PlaybackService._();
  static final PlaybackService I = PlaybackService._();

  AudioPlayer? _audio;
  VideoPlayerController? _video;

  // État courant
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  // Flux (broadcast) vers les écrans
  final _posCtl = StreamController<Duration>.broadcast();
  final _durCtl = StreamController<Duration>.broadcast();

  Stream<Duration> get positionStream => _posCtl.stream;
  Stream<Duration> get durationStream => _durCtl.stream;

  Duration get duration => _duration;
  Duration get position => _position;

  // ---------- BOUCLES (A/B) : partage cross-écrans ----------
  final _loopCtl = StreamController<LoopEvent>.broadcast();
  Stream<LoopEvent> get loopStream => _loopCtl.stream;

  /// Envoie un évènement de boucle (appelé par Player **ou** Editor).
  void updateLoop({required Duration a, required Duration b, required bool enabled}) {
    _loopCtl.add(LoopEvent(a: a, b: b, enabled: enabled));
  }

  /// Version pratique compatible avec ton appel dans Player:
  /// PlaybackService.I.subscribeLoop((a,b,enabled){ ... });
  StreamSubscription<LoopEvent> subscribeLoop(void Function(Duration a, Duration b, bool enabled) onEvent) {
    return _loopCtl.stream.listen((e) => onEvent(e.a, e.b, e.enabled));
  }

  // ---------- Rattacher / détacher un lecteur ----------
  void attach({AudioPlayer? audio, VideoPlayerController? video}) {
    if (audio != null) {
      _audio = audio;
      _video = null;
    }
    if (video != null) {
      _video = video;
      _audio = null;
    }
  }

  void detach() {
    _audio = null;
    _video = null;
  }

  // ---------- Mises à jour envoyées par le Player ----------
  void updateDuration(Duration d) {
    _duration = d;
    _durCtl.add(d);
  }

  void updatePosition(Duration p) {
    _position = p;
    _posCtl.add(p);
  }

  // ---------- Commandes depuis Editor ----------
  Future<void> seekSeconds(double seconds) async {
    final s = seconds.clamp(0.0, _duration.inMilliseconds / 1000.0);
    final d = Duration(milliseconds: (s * 1000).round());
    if (_video != null) {
      await _video!.seekTo(d);
    } else if (_audio != null) {
      await _audio!.seek(d);
    }
    updatePosition(d);
  }

  Future<void> playPause() async {
    if (_video != null) {
      final isPlaying = _video!.value.isPlaying;
      if (isPlaying) {
        await _video!.pause();
      } else {
        await _video!.play();
      }
    } else if (_audio != null) {
      final isPlaying = _audio!.playing;
      if (isPlaying) {
        await _audio!.pause();
      } else {
        await _audio!.play();
      }
    }
  }

  // ---------- Nettoyage global (facultatif) ----------
  Future<void> dispose() async {
    await _posCtl.close();
    await _durCtl.close();
    await _loopCtl.close();
  }
}