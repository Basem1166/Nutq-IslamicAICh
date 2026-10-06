import 'package:flutter/material.dart';

import '../../../core/phonetizer_settings_store.dart';
import '../../../theme/app_theme.dart';
import '../../activity/data/activity_store.dart';
import '../data/user_profile_store.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  Future<void> _editName(BuildContext context, String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit name'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result != null && result.trim().isNotEmpty) {
      await UserProfileStore.instance.saveName(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Profile',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 26,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 20),
            ValueListenableBuilder<String?>(
              valueListenable: UserProfileStore.instance.name,
              builder: (context, name, _) {
                final display = (name ?? '').trim().isEmpty ? 'Guest' : name!;
                return Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppTheme.outline),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.person,
                          color: AppTheme.primary,
                          size: 30,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          display,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Edit name',
                        onPressed: () => _editName(context, name),
                        icon: const Icon(Icons.edit_outlined),
                        color: AppTheme.primary,
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            const Text(
              'Your activity',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<ActivitySummary>(
              valueListenable: ActivityStore.instance.summary,
              builder: (context, summary, _) {
                return Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        icon: Icons.local_fire_department_rounded,
                        value: '${summary.currentStreak}',
                        label: 'Day streak',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.schedule_rounded,
                        value: '${summary.todayMinutes}/${summary.goalMinutes}m',
                        label: 'Today vs goal',
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 28),

            // ── Recitation Settings ─────────────────────────────────────────
            const Text(
              'Recitation settings',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Adjust the madd (elongation) lengths the phonetizer uses '
              'when evaluating your recitation. Values are in harakāt units.',
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.55),
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            const _PhonetizerSettings(),
            const SizedBox(height: 28),

            OutlinedButton.icon(
              onPressed: () => UserProfileStore.instance.signOut(),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                minimumSize: const Size.fromHeight(50),
                side: const BorderSide(color: AppTheme.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Phonetizer settings card ────────────────────────────────────────────────

class _PhonetizerSettings extends StatefulWidget {
  const _PhonetizerSettings();

  @override
  State<_PhonetizerSettings> createState() => _PhonetizerSettingsState();
}

class _PhonetizerSettingsState extends State<_PhonetizerSettings> {
  final PhonetizerSettingsStore _store = PhonetizerSettingsStore.instance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MaddSlider(
            label: 'Madd Munfaṣil',
            subtitle: 'Elongation between two separate words',
            notifier: _store.maddMonfaselLen,
            onChanged: _store.setMaddMonfaselLen,
          ),
          const Divider(height: 24, color: AppTheme.outline),
          _MaddSlider(
            label: 'Madd Muttaṣil',
            subtitle: 'Elongation where the hamza follows the madd letter',
            notifier: _store.maddMottaselLen,
            onChanged: _store.setMaddMottaselLen,
          ),
          const Divider(height: 24, color: AppTheme.outline),
          _MaddSlider(
            label: 'Madd Muttaṣil (waqf)',
            subtitle: 'Elongation when stopping at the end of a word',
            notifier: _store.maddMottaselWaqf,
            onChanged: _store.setMaddMottaselWaqf,
          ),
          const Divider(height: 24, color: AppTheme.outline),
          _MaddSlider(
            label: "Madd 'Āriḍ Liʼl-Sukūn",
            subtitle: "Elongation before a letter with sukūn at waqf",
            notifier: _store.maddAaredLen,
            onChanged: _store.setMaddAaredLen,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                await _store.resetToDefaults();
                setState(() {});
              },
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Reset to defaults'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primary,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MaddSlider extends StatelessWidget {
  const _MaddSlider({
    required this.label,
    required this.subtitle,
    required this.notifier,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final ValueNotifier<int> notifier;
  final Future<void> Function(int) onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: notifier,
      builder: (context, value, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.55),
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$value',
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            Slider(
              value: value.toDouble(),
              min: PhonetizerSettingsStore.minLen.toDouble(),
              max: PhonetizerSettingsStore.maxLen.toDouble(),
              divisions:
                  PhonetizerSettingsStore.maxLen - PhonetizerSettingsStore.minLen,
              activeColor: AppTheme.primary,
              inactiveColor: AppTheme.primary.withValues(alpha: 0.18),
              onChanged: (v) => onChanged(v.round()),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(
                PhonetizerSettingsStore.maxLen -
                    PhonetizerSettingsStore.minLen +
                    1,
                (i) {
                  final tick = PhonetizerSettingsStore.minLen + i;
                  return Text(
                    '$tick',
                    style: TextStyle(
                      fontSize: 11,
                      color: tick == value
                          ? AppTheme.primary
                          : Colors.black.withValues(alpha: 0.35),
                      fontWeight:
                          tick == value ? FontWeight.w700 : FontWeight.w400,
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Stat card (unchanged) ────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.secondary, size: 26),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.6),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
