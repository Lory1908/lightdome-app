import 'package:flutter/material.dart';

import '../controllers/device_controller.dart';
import 'tabs/dashboard_page.dart';
import 'tabs/programs_page.dart';
import 'tabs/settings_page.dart';
import 'tabs/create_page.dart';
import '../core/services/app_settings.dart';

class HomeScaffold extends StatefulWidget {
  const HomeScaffold({super.key});

  @override
  State<HomeScaffold> createState() => _HomeScaffoldState();
}

class _HomeScaffoldState extends State<HomeScaffold> {
  int _idx = 0;
  static const _pages = [
    DashboardPage(),
    CreatePage(),
    ProgramsPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    // No auto-discovery yet; user sets IP in Settings.
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = DeviceController.I;
    final settings = AppSettings.I;
    return AnimatedBuilder(
      animation: Listenable.merge([ctrl, settings]),
      builder: (context, _) {
        final pages = _pages;
        final idx = _idx.clamp(0, pages.length - 1);
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          extendBody: true,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Icon(
                              Icons.light_mode_rounded,
                              color: scheme.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'LightDome',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  ctrl.isConnected
                                      ? 'Cupola pronta${ctrl.ip.isNotEmpty ? ' • ${ctrl.ip}' : ''}'
                                      : 'In attesa di connessione',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: ctrl.isConnected
                                            ? scheme.secondary
                                            : scheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          IconButton.filledTonal(
                            tooltip: 'Cambia tema',
                            onPressed: () {
                              final brightness = Theme.of(context).brightness;
                              settings.setThemePreference(
                                brightness == Brightness.dark
                                    ? AppThemePreference.light
                                    : AppThemePreference.dark,
                              );
                            },
                            icon: Icon(
                              Theme.of(context).brightness == Brightness.dark
                                  ? Icons.light_mode_outlined
                                  : Icons.dark_mode_outlined,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 86),
                        child: pages[idx],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: scheme.outlineVariant),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: NavigationBar(
                      selectedIndex: idx,
                      onDestinationSelected: (i) => setState(() => _idx = i),
                      destinations: [
                        const NavigationDestination(
                          icon: Icon(Icons.space_dashboard_outlined),
                          selectedIcon: Icon(Icons.space_dashboard_rounded),
                          label: 'Home',
                        ),
                        const NavigationDestination(
                          icon: Icon(Icons.auto_awesome_outlined),
                          selectedIcon: Icon(Icons.auto_awesome_rounded),
                          label: 'Crea',
                        ),
                        const NavigationDestination(
                          icon: Icon(Icons.queue_music_outlined),
                          selectedIcon: Icon(Icons.queue_music_rounded),
                          label: 'Programmi',
                        ),
                        const NavigationDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings_rounded),
                          label: 'Altro',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
