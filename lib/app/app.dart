import 'package:flutter/material.dart';

import '../core/phonetizer_settings_store.dart';
import '../core/recitation/recitation_progress_store.dart';
import '../features/activity/data/activity_store.dart';
import '../features/auth/presentation/login_page.dart';
import '../features/navigation/presentation/app_shell.dart';
import '../features/profile/data/user_profile_store.dart';
import '../theme/app_theme.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nutq',
      theme: AppTheme.themeData(),
      home: const _AppGate(),
    );
  }
}

/// Loads the local profile, then shows the login screen until a profile exists,
/// otherwise the main app shell. Switches reactively on sign-in / sign-out.
class _AppGate extends StatefulWidget {
  const _AppGate();

  @override
  State<_AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<_AppGate> {
  late final Future<void> _bootstrap = _load();

  Future<void> _load() async {
    await Future.wait([
      UserProfileStore.instance.ensureLoaded(),
      ActivityStore.instance.ensureLoaded(),
      PhonetizerSettingsStore.instance.ensureLoaded(),
      RecitationProgressStore.instance.loadLast(
        defaultSurah: 18,
        defaultAyah: 25,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrap,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SplashScreen();
        }
        return ValueListenableBuilder<String?>(
          valueListenable: UserProfileStore.instance.name,
          builder: (context, name, _) {
            final signedIn = (name ?? '').trim().isNotEmpty;
            return signedIn ? const AppShell() : const LoginPage();
          },
        );
      },
    );
  }
}

/// Branded bootstrap screen shown while local stores are loading, so the
/// first frame matches the app's identity instead of a bare spinner.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
              ),
              child: const Icon(
                Icons.menu_book_rounded,
                color: Colors.white,
                size: 42,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Nutq',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
