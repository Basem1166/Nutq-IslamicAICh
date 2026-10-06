import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'reference_audio_service.dart';

/// Reusable reference-audio player: a play/stop button, a seek slider, and
/// optional Prev/Next buttons. Wraps the shared [ReferenceAudioService]
/// singleton and reflects its playback state.
///
/// Auto-plays the given `(surah, ayah)` when first shown and whenever they
/// change (e.g. after Prev/Next moves the parent to an adjacent ayah). Prev and
/// Next are disabled when their callback is null — the parent passes null at
/// the edges of whatever range it allows (e.g. the current page).
class ReferenceAudioPlayer extends StatefulWidget {
  const ReferenceAudioPlayer({
    super.key,
    required this.surah,
    required this.ayah,
    this.onPrev,
    this.onNext,
    this.autoPlay = true,
  });

  final int surah;
  final int ayah;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final bool autoPlay;

  @override
  State<ReferenceAudioPlayer> createState() => _ReferenceAudioPlayerState();
}

class _ReferenceAudioPlayerState extends State<ReferenceAudioPlayer> {
  final _service = ReferenceAudioService.instance;

  AudioPlaybackState _state = AudioPlaybackState.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _state = _service.state.value;
    _position = _service.position.value;
    _duration = _service.duration.value;
    _service.state.addListener(_onState);
    _service.position.addListener(_onPosition);
    _service.duration.addListener(_onDuration);
    if (widget.autoPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _play());
    }
  }

  @override
  void didUpdateWidget(covariant ReferenceAudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.surah != widget.surah || oldWidget.ayah != widget.ayah) {
      _play();
    }
  }

  @override
  void dispose() {
    _service.state.removeListener(_onState);
    _service.position.removeListener(_onPosition);
    _service.duration.removeListener(_onDuration);
    super.dispose();
  }

  void _onState() => setState(() => _state = _service.state.value);
  void _onPosition() => setState(() => _position = _service.position.value);
  void _onDuration() => setState(() => _duration = _service.duration.value);

  Future<void> _play() async {
    try {
      await _service.playAyah(widget.surah, widget.ayah);
    } on AudioPlaybackException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _navButton(
              icon: Icons.skip_previous_rounded,
              onTap: widget.onPrev,
            ),
            const SizedBox(width: 8),
            Expanded(child: _playButton()),
            const SizedBox(width: 8),
            _navButton(
              icon: Icons.skip_next_rounded,
              onTap: widget.onNext,
            ),
          ],
        ),
        if (_duration > Duration.zero) ...[
          const SizedBox(height: 4),
          _seekSlider(),
        ],
      ],
    );
  }

  Widget _navButton({required IconData icon, VoidCallback? onTap}) {
    return IconButton.outlined(
      onPressed: onTap,
      icon: Icon(icon),
      iconSize: 26,
      style: IconButton.styleFrom(
        foregroundColor: AppTheme.primary,
        side: BorderSide(
          color: AppTheme.primary.withValues(alpha: onTap == null ? 0.25 : 1),
        ),
        minimumSize: const Size(52, 52),
      ),
    );
  }

  Widget _playButton() {
    final IconData icon;
    final String label;
    Widget? leading;

    switch (_state) {
      case AudioPlaybackState.loading:
        icon = Icons.volume_up_rounded;
        label = 'Loading…';
        leading = const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case AudioPlaybackState.playing:
        icon = Icons.stop_rounded;
        label = 'Stop';
        leading = null;
      case AudioPlaybackState.completed:
        icon = Icons.replay_rounded;
        label = 'Play Again';
        leading = null;
      case AudioPlaybackState.idle:
        icon = Icons.volume_up_rounded;
        label = 'Hear Reference';
        leading = null;
    }

    return OutlinedButton.icon(
      onPressed: () async {
        if (_state == AudioPlaybackState.playing) {
          await _service.stop();
          return;
        }
        await _play();
      },
      icon: leading ?? Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.primary,
        side: const BorderSide(color: AppTheme.primary),
        minimumSize: const Size.fromHeight(52),
      ),
    );
  }

  Widget _seekSlider() {
    final totalMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, totalMs);
    final value = totalMs > 0 ? posMs / totalMs : 0.0;

    String fmt(Duration d) {
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: value.toDouble(),
            activeColor: AppTheme.primary,
            inactiveColor: AppTheme.primary.withValues(alpha: 0.2),
            onChanged: (v) {
              _service.seek(Duration(milliseconds: (v * totalMs).round()));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                fmt(Duration(milliseconds: posMs)),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.black.withValues(alpha: 0.55),
                ),
              ),
              Text(
                fmt(_duration),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.black.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
