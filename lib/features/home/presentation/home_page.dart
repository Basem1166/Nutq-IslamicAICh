import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quran/quran.dart' as quran;

import '../../../core/recitation/recitation_progress_store.dart';
import '../../../theme/app_theme.dart';
import '../../activity/data/activity_store.dart';
import '../../profile/data/user_profile_store.dart';
import '../../quran/presentation/surah_reader_page.dart';
import 'streaming_recitation_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, this.onViewAllQuran, this.onSearchMeaning});

  final VoidCallback? onViewAllQuran;
  final ValueChanged<String>? onSearchMeaning;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            decoration: const BoxDecoration(
              color: AppTheme.primary,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.42),
                        ),
                      ),
                      child: const Icon(
                        Icons.person,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Welcome back',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          ValueListenableBuilder<String?>(
                            valueListenable: UserProfileStore.instance.name,
                            builder: (context, name, _) {
                              final display = (name ?? '').trim().isEmpty
                                  ? 'Guest'
                                  : name!;
                              return Text(
                                display,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Notifications',
                      onPressed: () {
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            const SnackBar(
                              content: Text('No new notifications yet'),
                            ),
                          );
                      },
                      icon: const Icon(
                        Icons.notifications_none_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'As-salamu alaykum',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder<ActivitySummary>(
                  valueListenable: ActivityStore.instance.summary,
                  builder: (context, summary, _) {
                    return Row(
                      children: [
                        Expanded(
                          child: _StatBubble(
                            icon: Icons.local_fire_department_rounded,
                            label: '${summary.currentStreak} day streak',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatBubble(
                            icon: Icons.schedule_rounded,
                            label:
                                '${summary.todayMinutes}/${summary.goalMinutes}m today',
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSearchMeaning?.call(''),
                  child: Container(
                    height: 54,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.outline),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.search, color: AppTheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Search by meaning,topic or verse',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.black.withValues(alpha: 0.56),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Search by voice',
                          onPressed: () => onSearchMeaning?.call(''),
                          icon: const Icon(Icons.mic_none_rounded),
                          color: AppTheme.primary,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryLight.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'AI COACH',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.graphic_eq_rounded,
                        size: 30,
                        color: AppTheme.primary.withValues(alpha: 0.75),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Recitation correction',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Detect Tajweed errors instantly with our advanced audio analysis',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.72),
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _WaveformPlaceholder(),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        final position =
                            RecitationProgressStore.instance.last.value;
                        final surah = position?.surah ?? 18;
                        final ayah = position?.ayah ?? 25;
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => StreamingRecitationPage(
                              surahNumber: surah,
                              ayahNumber: ayah,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.mic_rounded),
                      label: const Text('Start Recording'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.secondary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Continue Reading',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onViewAllQuran,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'View All',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: ValueListenableBuilder<RecitationPosition?>(
                valueListenable: RecitationProgressStore.instance.last,
                builder: (context, position, _) {
                  final surah = position?.surah ?? 18;
                  final ayah = position?.ayah ?? 25;
                  return _ContinueReadingCard(
                    surahNumber: surah,
                    ayahNumber: ayah,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (context) => SurahReaderPage(
                            surahNumber: surah,
                            initialAyahNumber: ayah,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: const [
                Expanded(
                  child: Text(
                    'Word of the Day',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: _WordOfTheDayCard(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _WordOfTheDayCard extends StatelessWidget {
  const _WordOfTheDayCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.secondaryBackground,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'رَحْمَة',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Rahmah',
                  style: TextStyle(
                    color: AppTheme.secondary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Mercy',
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.62),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Tooltip(
            message: 'Play pronunciation',
            child: Material(
              color: Colors.white,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  HapticFeedback.selectionClick();
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(
                        content: Text('Audio pronunciation coming soon'),
                      ),
                    );
                },
                child: const SizedBox(
                  width: 52,
                  height: 52,
                  child: Icon(Icons.volume_up_rounded, color: AppTheme.secondary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueReadingCard extends StatelessWidget {
  const _ContinueReadingCard({
    required this.surahNumber,
    required this.ayahNumber,
    required this.onTap,
  });

  final int surahNumber;
  final int ayahNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surahName = quran.getSurahNameEnglish(surahNumber);
    final revelation = quran.getPlaceOfRevelation(surahNumber);
    final totalAyahs = quran.getVerseCount(surahNumber);
    final progress = ayahNumber / totalAyahs;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.menu_book_rounded,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          surahName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryLight.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          revelation,
                          style: const TextStyle(
                            color: AppTheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Ayah $ayahNumber',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.62),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 8,
                      backgroundColor: AppTheme.outline.withValues(alpha: 0.35),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppTheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatBubble extends StatelessWidget {
  const _StatBubble({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformPlaceholder extends StatelessWidget {
  const _WaveformPlaceholder();

  @override
  Widget build(BuildContext context) {
    const heights = [
      8.0,
      14.0,
      10.0,
      18.0,
      12.0,
      22.0,
      16.0,
      26.0,
      18.0,
      14.0,
      28.0,
      20.0,
      24.0,
      12.0,
      16.0,
      22.0,
      10.0,
      18.0,
    ];

    return SizedBox(
      height: 46,
      child: Center(
        child: SizedBox(
          width: 210,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: heights
                .map(
                  (height) => Container(
                    width: 4,
                    height: height,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}
