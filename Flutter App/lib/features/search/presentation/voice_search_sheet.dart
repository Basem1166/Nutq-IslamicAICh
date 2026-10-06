import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../theme/app_theme.dart';

/// Opens the voice search sheet and resolves to the spoken query, or null if
/// the user cancelled or nothing was recognized.
Future<String?> showVoiceSearchSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const VoiceSearchSheet(),
  );
}

enum VoiceSearchLanguage {
  arabic('العربية', 'ar', 'ar-SA', TextDirection.rtl),
  english('English', 'en', 'en-US', TextDirection.ltr);

  const VoiceSearchLanguage(
    this.label,
    this.code,
    this.fallbackLocaleId,
    this.direction,
  );

  final String label;
  final String code;

  /// Used when the recognizer doesn't report its supported locales (common on
  /// newer Android versions).
  final String fallbackLocaleId;
  final TextDirection direction;
}

enum _Phase { initializing, listening, idle, unavailable }

/// Speech-to-text capture for the meaning search. Listens immediately, shows
/// the live transcript, and pops with the final text once the user stops
/// speaking.
class VoiceSearchSheet extends StatefulWidget {
  const VoiceSearchSheet({super.key});

  @override
  State<VoiceSearchSheet> createState() => _VoiceSearchSheetState();
}

class _VoiceSearchSheetState extends State<VoiceSearchSheet> {
  static const String _languageKey = 'voice_search_language';

  final SpeechToText _speech = SpeechToText();

  _Phase _phase = _Phase.initializing;
  VoiceSearchLanguage _language = VoiceSearchLanguage.english;
  final Map<VoiceSearchLanguage, String> _localeIds = {};
  String _transcript = '';
  String? _message;
  bool _permissionDenied = false;
  bool _submitted = false;
  double _level = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _speech.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_languageKey);
    final deviceIsArabic =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ar';
    _language = VoiceSearchLanguage.values.firstWhere(
      (lang) => lang.name == saved,
      orElse: () => deviceIsArabic
          ? VoiceSearchLanguage.arabic
          : VoiceSearchLanguage.english,
    );

    bool available;
    try {
      available = await _speech.initialize(
        onError: _onError,
        onStatus: _onStatus,
      );
    } catch (_) {
      available = false;
    }
    if (!mounted) return;
    if (!available) {
      _permissionDenied = !await _speech.hasPermission;
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unavailable;
        _message = _permissionDenied
            ? 'Microphone access is needed for voice search.'
            : "Speech recognition isn't available on this device. On Android, "
                  'make sure the Google app and its speech services are '
                  'installed and enabled.';
      });
      return;
    }

    await _resolveLocales();
    await _startListening();
  }

  /// Picks the best recognizer locale for each language, preferring a common
  /// regional variant when several are installed.
  Future<void> _resolveLocales() async {
    List<String> ids;
    try {
      ids = (await _speech.locales()).map((l) => l.localeId).toList();
    } catch (_) {
      ids = const [];
    }
    String? pick(String code, List<String> preferred) {
      String norm(String id) => id.replaceAll('_', '-').toLowerCase();
      for (final want in preferred) {
        for (final id in ids) {
          if (norm(id) == want) return id;
        }
      }
      for (final id in ids) {
        if (norm(id).startsWith('$code-') || norm(id) == code) return id;
      }
      return null;
    }

    final arabic = pick('ar', const ['ar-sa', 'ar-eg', 'ar-ae']);
    final english = pick('en', const ['en-us', 'en-gb']);
    if (arabic != null) _localeIds[VoiceSearchLanguage.arabic] = arabic;
    if (english != null) _localeIds[VoiceSearchLanguage.english] = english;
  }

  Future<void> _startListening() async {
    HapticFeedback.selectionClick();
    setState(() {
      _phase = _Phase.listening;
      _transcript = '';
      _message = null;
      _level = 0;
    });
    try {
      await _speech.listen(
        onResult: _onResult,
        onSoundLevelChange: (level) {
          if (!mounted) return;
          // Platform levels are roughly -2..10 dB; map to 0..1.
          setState(() => _level = ((level + 2) / 12).clamp(0.0, 1.0));
        },
        listenOptions: SpeechListenOptions(
          localeId: _localeIds[_language] ?? _language.fallbackLocaleId,
          listenMode: ListenMode.search,
          partialResults: true,
          cancelOnError: true,
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _message = 'Could not start listening. Tap the mic to try again.';
      });
    }
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    if (!mounted) return;
    setState(() => _phase = _Phase.idle);
  }

  void _onResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    setState(() => _transcript = result.recognizedWords);
    if (result.finalResult && _transcript.trim().isNotEmpty) {
      _submit();
    }
  }

  void _onStatus(String status) {
    if (!mounted) return;
    if ((status == SpeechToText.doneStatus ||
            status == SpeechToText.notListeningStatus) &&
        _phase == _Phase.listening) {
      setState(() {
        _phase = _Phase.idle;
        _level = 0;
        if (_transcript.trim().isEmpty) {
          _message ??= "Didn't catch that. Tap the mic to try again.";
        }
      });
    }
  }

  void _onError(SpeechRecognitionError error) {
    if (!mounted) return;
    final String message;
    switch (error.errorMsg) {
      case 'error_no_match':
      case 'error_speech_timeout':
        message = "Didn't catch that. Tap the mic to try again.";
      case 'error_network':
      case 'error_network_timeout':
      case 'error_server':
        message = 'Voice search needs an internet connection.';
      case 'error_permission':
      case 'error_insufficient_permissions':
        _permissionDenied = true;
        message = 'Microphone access is needed for voice search.';
      case 'error_language_not_supported':
      case 'error_language_unavailable':
        message =
            '${_language.label} speech isn\'t available on this device. '
            'Try the other language.';
      default:
        message = 'Something went wrong. Tap the mic to try again.';
    }
    setState(() {
      _phase = _Phase.idle;
      _level = 0;
      _message = message;
    });
  }

  Future<void> _setLanguage(VoiceSearchLanguage language) async {
    if (language == _language) return;
    await _speech.cancel();
    setState(() => _language = language);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, language.name);
    if (!mounted || _phase == _Phase.unavailable) return;
    await _startListening();
  }

  void _submit() {
    final text = _transcript.trim();
    // A late final result can arrive after a manual Search tap; pop only once.
    if (text.isEmpty || _submitted) return;
    _submitted = true;
    _speech.stop();
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final listening = _phase == _Phase.listening;
    final hasText = _transcript.trim().isNotEmpty;
    final status = switch (_phase) {
      _Phase.initializing => 'Preparing…',
      _Phase.listening => 'Listening… speak your search',
      _Phase.idle =>
        hasText ? 'Tap Search to continue' : 'Tap the mic to speak',
      _Phase.unavailable => 'Voice search unavailable',
    };

    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        24 + MediaQuery.of(context).viewPadding.bottom,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: AppTheme.outline,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Voice search',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          SegmentedButton<VoiceSearchLanguage>(
            segments: [
              for (final lang in VoiceSearchLanguage.values)
                ButtonSegment(value: lang, label: Text(lang.label)),
            ],
            selected: {_language},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => _setLanguage(selection.first),
          ),
          const SizedBox(height: 24),
          Semantics(
            button: true,
            label: listening ? 'Stop listening' : 'Start listening',
            enabled:
                _phase != _Phase.unavailable && _phase != _Phase.initializing,
            child: GestureDetector(
              onTap: switch (_phase) {
                _Phase.listening => _stopListening,
                _Phase.idle => _startListening,
                _ => null,
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _phase == _Phase.unavailable
                      ? AppTheme.outline
                      : listening
                      ? AppTheme.secondary
                      : AppTheme.primary,
                  boxShadow: [
                    if (listening)
                      BoxShadow(
                        color: AppTheme.secondary.withValues(alpha: 0.35),
                        blurRadius: 12 + 28 * _level,
                        spreadRadius: 2 + 14 * _level,
                      ),
                  ],
                ),
                child: Icon(
                  listening ? Icons.stop_rounded : Icons.mic_rounded,
                  color: Colors.white,
                  size: 44,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              _message ?? status,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.black.withValues(alpha: 0.62),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.outline),
              ),
              child: Semantics(
                liveRegion: true,
                label: 'Recognized text',
                child: Text(
                  hasText ? _transcript : '…',
                  textDirection: _language.direction,
                  textAlign: TextAlign.start,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _permissionDenied
                    ? ElevatedButton(
                        onPressed: openAppSettings,
                        child: const Text('Open settings'),
                      )
                    : ElevatedButton(
                        onPressed: hasText ? _submit : null,
                        child: const Text('Search'),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
