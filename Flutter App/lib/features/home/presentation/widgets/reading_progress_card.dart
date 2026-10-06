import 'package:flutter/material.dart';
import 'package:quran/quran.dart' as quran;

import '../../../../core/quran/surah_names.dart';
import '../../../../theme/app_theme.dart';

/// Surah + ayah resume point with a within-surah progress bar. Used by the
/// home page's "Continue Reading" and the reading history page.
class ReadingProgressCard extends StatelessWidget {
  const ReadingProgressCard({
    super.key,
    required this.surahNumber,
    required this.ayahNumber,
    required this.onTap,
  });

  final int surahNumber;
  final int ayahNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = surahName(surahNumber);
    final revelation = quran.getPlaceOfRevelation(surahNumber);
    final totalAyahs = quran.getVerseCount(surahNumber);
    final progress = (ayahNumber / totalAyahs).clamp(0.0, 1.0);
    final percent = (progress * 100).round();

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
                          title,
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
                    'Ayah $ayahNumber of $totalAyahs · $percent%',
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
