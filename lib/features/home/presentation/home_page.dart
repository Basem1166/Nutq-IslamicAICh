import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/recitation/recitation_progress_store.dart';
import '../../../theme/app_theme.dart';
import '../../activity/data/activity_store.dart';
import '../../profile/data/user_profile_store.dart';
import '../../quran/presentation/surah_reader_page.dart';
import 'reading_history_page.dart';
import 'streaming_recitation_page.dart';
import 'widgets/reading_progress_card.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, this.onSearchMeaning});

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
                        // Resume at the last ayah read or recited.
                        final position =
                            RecitationProgressStore.instance.last.value ??
                            const RecitationPosition(1, 1);
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => StreamingRecitationPage(
                              surahNumber: position.surah,
                              ayahNumber: position.ayah,
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
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => const ReadingHistoryPage(),
                    ),
                  ),
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
                  final surah = position?.surah ?? 1;
                  final ayah = position?.ayah ?? 1;
                  return ReadingProgressCard(
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
        ],
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
