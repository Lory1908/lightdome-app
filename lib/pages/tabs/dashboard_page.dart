import 'package:flutter/material.dart';

import '../../controllers/device_controller.dart';
import '../../core/models/pattern.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = DeviceController.I;
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        final state = ctrl.state;
        final metrics = <Widget>[
          _metricCard(
            context,
            'Modalità',
            _modeLabel(state.mode),
            Icons.bolt_rounded,
          ),
          _metricCard(
            context,
            'Master',
            '${(state.brightness * 100).round()}%',
            Icons.brightness_6_rounded,
          ),
          _metricCard(
            context,
            'Gamma',
            state.gamma.toStringAsFixed(1),
            Icons.show_chart_rounded,
          ),
          if (ctrl.pattern.type != PatternType.none)
            _metricCard(
              context,
              'Pattern',
              _patternSummary(ctrl.pattern),
              Icons.graphic_eq_rounded,
            ),
          if (state.programName?.isNotEmpty == true)
            _metricCard(
              context,
              'Programma',
              state.programName!,
              Icons.queue_music_rounded,
            ),
          if (state.sr > 0)
            _metricCard(
              context,
              'Campionamento',
              '${state.sr} Hz',
              Icons.speed_rounded,
            ),
        ];

        return RefreshIndicator(
          onRefresh: ctrl.refreshOnce,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 820 ? 3 : 2;
              const gap = 12.0;
              final available = constraints.maxWidth - 32;
              final cardWidth = (available - gap * (columns - 1)) / columns;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                children: [
                  Text(
                    'La tua luce',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Controllo essenziale, risposta immediata.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _heroCard(context, ctrl),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final metric in metrics)
                        SizedBox(width: cardWidth, child: metric),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _heroCard(BuildContext context, DeviceController ctrl) {
    final scheme = Theme.of(context).colorScheme;
    final state = ctrl.state;
    final level = (state.y * 100).clamp(0, 100).round();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 520;
            final lamp = Container(
              width: compact ? 118 : 152,
              height: compact ? 118 : 152,
              decoration: BoxDecoration(
                color: state.on
                    ? scheme.primary.withValues(alpha: 0.16 + state.y * 0.18)
                    : scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
                border: Border.all(
                  color: state.on ? scheme.primary : scheme.outlineVariant,
                  width: 1.5,
                ),
                boxShadow: state.on
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(
                            alpha: 0.2 + state.y * 0.2,
                          ),
                          blurRadius: 36,
                          spreadRadius: 2,
                        ),
                      ]
                    : const [],
              ),
              child: Icon(
                state.on ? Icons.light_mode_rounded : Icons.light_mode_outlined,
                size: compact ? 54 : 68,
                color: state.on ? scheme.primary : scheme.onSurfaceVariant,
              ),
            );
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      ctrl.isConnected
                          ? Icons.wifi_rounded
                          : Icons.wifi_off_rounded,
                      size: 17,
                      color: ctrl.isConnected ? scheme.secondary : scheme.error,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      ctrl.isConnected ? 'CONNESSA' : 'NON CONNESSA',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: ctrl.isConnected
                            ? scheme.secondary
                            : scheme.error,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  state.on ? 'Cupola accesa' : 'Cupola spenta',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$level%',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w300,
                    color: state.on ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: ctrl.isConnected ? ctrl.off : null,
                      icon: const Icon(Icons.power_settings_new_rounded),
                      label: const Text('Spegni'),
                    ),
                    OutlinedButton.icon(
                      onPressed: ctrl.refreshOnce,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Aggiorna'),
                    ),
                  ],
                ),
              ],
            );
            if (compact) {
              return Column(
                children: [
                  lamp,
                  const SizedBox(height: 22),
                  Align(alignment: Alignment.centerLeft, child: details),
                ],
              );
            }
            return Row(
              children: [
                lamp,
                const SizedBox(width: 28),
                Expanded(child: details),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _metricCard(
    BuildContext context,
    String label,
    String value,
    IconData icon,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.secondary, size: 21),
            const SizedBox(height: 18),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }

  String _modeLabel(String mode) {
    switch (mode) {
      case 'live':
      case 'live_or_idle':
        return 'Live';
      case 'program':
        return 'Programma';
      case 'program_ram':
      case 'ram':
        return 'Pattern RAM';
      case 'idle':
        return 'In attesa';
      default:
        return mode;
    }
  }

  String _patternSummary(PatternConfig config) {
    switch (config.type) {
      case PatternType.sine:
        return 'Sine ${config.freqHz.toStringAsFixed(1)} Hz';
      case PatternType.pulse:
        return 'Pulse ${config.freqHz.toStringAsFixed(1)} Hz';
      case PatternType.micReactive:
        return 'Mic reattivo';
      case PatternType.songWaveSpotify:
        return 'Spotify';
      case PatternType.songWaveOpen:
        return 'File locale';
      case PatternType.none:
        return 'Nessuno';
    }
  }
}
