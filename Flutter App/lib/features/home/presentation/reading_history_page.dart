import 'package:flutter/material.dart';

import '../../../core/recitation/recitation_progress_store.dart';
import '../../../theme/app_theme.dart';
import '../../quran/presentation/surah_reader_page.dart';
import 'widgets/reading_progress_card.dart';

/// Every surah the user has read or recited, most recent first, each with its
/// resume ayah and progress. Opened from "View All" on the home page.
class ReadingHistoryPage extends StatelessWidget {
  const ReadingHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Reading History'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: ValueListenableBuilder<List<ReadingHistoryEntry>>(
        valueListenable: RecitationProgressStore.instance.history,
        builder: (context, history, _) {
          if (history.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Surahs you read or recite will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.black.withValues(alpha: 0.6),
                  ),
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            itemCount: history.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final entry = history[index];
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: ReadingProgressCard(
                  surahNumber: entry.surah,
                  ayahNumber: entry.ayah,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => SurahReaderPage(
                          surahNumber: entry.surah,
                          initialAyahNumber: entry.ayah,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
