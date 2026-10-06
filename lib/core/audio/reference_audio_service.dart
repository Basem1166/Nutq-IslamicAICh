import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum AudioPlaybackState { idle, loading, playing, completed }

class AudioPlaybackException implements Exception {
  AudioPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Streams the reference Husary recitation for a given ayah from everyayah.com.
class ReferenceAudioService {
  ReferenceAudioService._() {
    _player.onPlayerStateChanged.listen(_onPlayerStateChanged);
    _player.onPositionChanged.listen((d) => position.value = d);
    _player.onDurationChanged.listen((d) => duration.value = d);
  }

  static final instance = ReferenceAudioService._();

  final _player = AudioPlayer();

  final state = ValueNotifier<AudioPlaybackState>(AudioPlaybackState.idle);
  final position = ValueNotifier<Duration>(Duration.zero);
  final duration = ValueNotifier<Duration>(Duration.zero);

  static String _url(int surah, int ayah) {
    final s = surah.toString().padLeft(3, '0');
    final a = ayah.toString().padLeft(3, '0');
    return 'https://everyayah.com/data/Husary_128kbps/$s$a.mp3';
  }

  void _onPlayerStateChanged(PlayerState ps) {
    if (ps == PlayerState.playing) {
      state.value = AudioPlaybackState.playing;
    } else if (ps == PlayerState.completed) {
      state.value = AudioPlaybackState.completed;
      position.value = Duration.zero;
    } else {
      // stopped, paused, disposed, or any future variant → idle
      if (state.value != AudioPlaybackState.idle) {
        state.value = AudioPlaybackState.idle;
      }
    }
  }

  Future<void> playAyah(int surah, int ayah) async {
    // Reset the player if a previous clip completed (replay case).
    if (state.value == AudioPlaybackState.completed) {
      await stop();
    }
    state.value = AudioPlaybackState.loading;
    duration.value = Duration.zero;
    position.value = Duration.zero;
    try {
      await _player.play(UrlSource(_url(surah, ayah)));
    } catch (e) {
      state.value = AudioPlaybackState.idle;
      throw AudioPlaybackException(
        'No internet connection. Please check your network and try again.',
      );
    }
  }

  Future<void> seek(Duration target) async {
    if (state.value == AudioPlaybackState.idle) return;
    await _player.seek(target);
  }

  Future<void> stop() async {
    await _player.stop();
    state.value = AudioPlaybackState.idle;
    position.value = Duration.zero;
  }

  void dispose() {
    _player.dispose();
    state.dispose();
    position.dispose();
    duration.dispose();
  }
}
