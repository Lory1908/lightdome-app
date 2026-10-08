import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/services/audio_capture_source.dart';
import '../../core/services/audio_feature_processor.dart';
import '../../controllers/device_controller.dart';

/// Preparation UI: does not present a capture control without a real provider.
class AudioFoundationPanel extends StatefulWidget {
  const AudioFoundationPanel({super.key});

  @override
  State<AudioFoundationPanel> createState() => _AudioFoundationPanelState();
}

class _AudioFoundationPanelState extends State<AudioFoundationPanel> {
  final AudioCaptureSource source = const UnavailableSystemAudioSource();
  double gain = 1, gate = .05, attack = .65, release = .3, min = 0, max = 1;
  String? fallback;
  String? fallbackMessage;
  bool savingFallback = false;
  late final Future<List<String>> patterns;

  @override
  void initState() {
    super.initState();
    patterns = DeviceController.I.listPrograms();
  }

  Future<void> selectFallback(String? chosen) async {
    if (!DeviceController.I.isConnected) {
      setState(
        () => fallbackMessage = 'Connetti la cupola per applicare la scelta.',
      );
      return;
    }
    setState(() => savingFallback = true);
    try {
      await DeviceController.I.setAudioFallback(chosen);
      if (mounted) {
        setState(() {
          fallback = chosen;
          fallbackMessage = chosen == null
              ? 'In caso di interruzione la luce si spegnerà gradualmente.'
              : 'In caso di interruzione partirà il pattern $chosen.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => fallbackMessage =
              'Non posso configurare il recupero. Verifica connessione e versione firmware.',
        );
      }
    } finally {
      if (mounted) setState(() => savingFallback = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tuning = AudioTuning(
      gain: gain,
      gate: gate,
      attack: attack,
      release: release,
      minimum: min,
      maximum: max,
    );
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.computer_rounded),
        title: const Text('Audio del computer'),
        subtitle: const Text('Preparazione della modalità a bande'),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Sorgente: ${source.label}'),
            subtitle: Text(
              kIsWeb
                  ? 'Il browser può richiedere la condivisione esplicita di una scheda o dello schermo, e non garantisce audio di sistema.'
                  : source.explanation,
            ),
            trailing: const Chip(label: Text('Non attiva')),
          ),
          const Text('Trasmissione: ferma · Nessun audio acquisito'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: const [
              Chip(label: Text('Volume —')),
              Chip(label: Text('Bassi —')),
              Chip(label: Text('Medi —')),
              Chip(label: Text('Alti —')),
              Chip(label: Text('Battito —')),
            ],
          ),
          const SizedBox(height: 8),
          _slider('Sensibilità', gain, 0, 3, (v) => setState(() => gain = v)),
          _slider(
            'Soglia rumore',
            gate,
            0,
            .5,
            (v) => setState(() => gate = v),
          ),
          _slider(
            'Reazione in salita',
            attack,
            0,
            1,
            (v) => setState(() => attack = v),
          ),
          _slider(
            'Ritorno alla calma',
            release,
            0,
            1,
            (v) => setState(() => release = v),
          ),
          _slider(
            'Luce minima',
            min,
            0,
            .9,
            (v) => setState(() => min = v.clamp(0, max)),
          ),
          _slider(
            'Luce massima',
            max,
            .1,
            1,
            (v) => setState(() => max = v.clamp(min, 1)),
          ),
          Text(
            'In assenza di audio: dissolvenza, oppure pattern di riserva selezionato. La protezione sarà eseguita dal firmware.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          FutureBuilder<List<String>>(
            future: patterns,
            builder: (context, snapshot) {
              final names = snapshot.data ?? const <String>[];
              return DropdownButtonFormField<String>(
                key: ValueKey(fallback),
                initialValue: fallback ?? '',
                decoration: const InputDecoration(
                  labelText: 'Quando l’audio si interrompe',
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Spegni gradualmente'),
                  ),
                  ...names.map(
                    (name) => DropdownMenuItem(
                      value: name,
                      child: Text('Avvia $name'),
                    ),
                  ),
                ],
                onChanged: savingFallback
                    ? null
                    : (choice) => selectFallback(choice == '' ? null : choice),
              );
            },
          ),
          if (fallbackMessage != null) Text(fallbackMessage!),
          const SizedBox(height: 8),
          Text(
            'Parametri preparati: gain ${tuning.gain.toStringAsFixed(2)}, gate ${tuning.gate.toStringAsFixed(2)}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          const SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: null,
              child: Text('Avvia audio del computer (non disponibile)'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String title,
    double value,
    double minValue,
    double maxValue,
    ValueChanged<double> changed,
  ) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(title)),
          Text(value.toStringAsFixed(2)),
        ],
      ),
      Slider(
        value: value.clamp(minValue, maxValue),
        min: minValue,
        max: maxValue,
        onChanged: changed,
      ),
    ],
  );
}
