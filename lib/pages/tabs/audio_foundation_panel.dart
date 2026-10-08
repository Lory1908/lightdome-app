import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/audio_capture_source.dart';
import '../../core/services/audio_feature_processor.dart';
import '../../core/services/audio_stream_coordinator.dart';
import '../../core/services/system_audio_source.dart';
import '../../controllers/device_controller.dart';

/// System-audio controls. The platform source stays unavailable outside Windows.
class AudioFoundationPanel extends StatefulWidget {
  const AudioFoundationPanel({super.key});

  @override
  State<AudioFoundationPanel> createState() => _AudioFoundationPanelState();
}

class _AudioFoundationPanelState extends State<AudioFoundationPanel> {
  late final AudioCaptureSource source;
  AudioStreamCoordinator? session;
  AudioFeatures? features;
  bool starting = false;
  String? streamMessage;
  double gain = 1, gate = .05, attack = .65, release = .3, min = 0, max = 1;
  double volumeWeight = .4;
  double bassWeight = .35;
  double midWeight = .15;
  double trebleWeight = .1;
  double beatBoost = .15;
  String? fallback;
  String? fallbackMessage;
  bool savingFallback = false;
  late final Future<List<String>> patterns;

  @override
  void initState() {
    super.initState();
    source = createSystemAudioSource();
    patterns = DeviceController.I.listPrograms();
  }

  @override
  void dispose() {
    final active = session;
    session = null;
    if (active != null) unawaited(active.stop());
    super.dispose();
  }

  AudioTuning get tuning => AudioTuning(
    gain: gain,
    gate: gate,
    attack: attack,
    release: release,
    minimum: min,
    maximum: max,
    volumeWeight: volumeWeight,
    bassWeight: bassWeight,
    midWeight: midWeight,
    trebleWeight: trebleWeight,
    beatBoost: beatBoost,
  );

  Future<void> toggleAudio() async {
    final current = session;
    if (current?.running == true) {
      setState(() {
        starting = true;
        streamMessage = 'Arresto audio…';
      });
      await current!.stop();
      if (mounted) {
        setState(() {
          starting = false;
          session = null;
          streamMessage = 'Audio fermato.';
        });
      }
      return;
    }
    if (!source.isSupported || !DeviceController.I.isConnected) return;
    setState(() {
      starting = true;
      streamMessage = 'Avvio audio Windows…';
    });
    final processor = AudioFeatureProcessor(tuning: tuning);
    late final AudioStreamCoordinator next;
    next = AudioStreamCoordinator(
      source: source,
      processor: processor,
      sendLevel: DeviceController.I.sendAudioLevel,
      onAudioLost: () async {
        await DeviceController.I.finishAudioStream(fallback: fallback);
        if (mounted) {
          setState(() {
            if (identical(session, next)) session = null;
            starting = false;
            streamMessage = 'Audio interrotto: recupero applicato.';
          });
        }
      },
      onFeatures: (value) {
        if (mounted) setState(() => features = value);
      },
    );
    session = next;
    try {
      await next.start();
      if (mounted) {
        setState(() {
          starting = false;
          streamMessage = 'Audio Windows in trasmissione.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          starting = false;
          if (identical(session, next)) session = null;
          streamMessage = 'Avvio non riuscito: ${_friendlyError(error)}';
        });
      }
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    final marker = text.indexOf(': ');
    return marker >= 0 ? text.substring(marker + 2) : text;
  }

  void updateTuning(VoidCallback change) {
    setState(change);
    session?.processor.tuning = tuning;
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
    final active = session?.running == true;
    final currentFeatures = features;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.computer_rounded),
        title: const Text('Audio del computer'),
        subtitle: const Text('Luce reattiva all’audio riprodotto da Windows'),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Sorgente: ${source.label}'),
            subtitle: Text(source.explanation),
            trailing: Chip(
              label: Text(
                active
                    ? 'In uso'
                    : (source.isSupported ? 'Disponibile' : 'Non disponibile'),
              ),
            ),
          ),
          Text(
            active
                ? 'Trasmissione attiva verso la cupola.'
                : 'Trasmissione ferma · Nessun audio acquisito.',
          ),
          if (streamMessage != null) Text(streamMessage!),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Chip(label: Text('Volume ${_meter(currentFeatures?.volume)}')),
              Chip(label: Text('Bassi ${_meter(currentFeatures?.bass)}')),
              Chip(label: Text('Medi ${_meter(currentFeatures?.mid)}')),
              Chip(label: Text('Alti ${_meter(currentFeatures?.treble)}')),
              Chip(
                label: Text(
                  currentFeatures == null
                      ? 'Battito —'
                      : (currentFeatures.beat ? 'Battito ●' : 'Battito ○'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _slider(
            'Sensibilità',
            gain,
            0,
            3,
            (v) => updateTuning(() => gain = v),
          ),
          _slider(
            'Soglia rumore',
            gate,
            0,
            .5,
            (v) => updateTuning(() => gate = v),
          ),
          _slider(
            'Reazione in salita',
            attack,
            0,
            1,
            (v) => updateTuning(() => attack = v),
          ),
          _slider(
            'Ritorno alla calma',
            release,
            0,
            1,
            (v) => updateTuning(() => release = v),
          ),
          _slider(
            'Luce minima',
            min,
            0,
            .9,
            (v) => updateTuning(() => min = v.clamp(0, max)),
          ),
          _slider(
            'Luce massima',
            max,
            .1,
            1,
            (v) => updateTuning(() => max = v.clamp(min, 1)),
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Risposta alle frequenze'),
          ),
          _slider(
            'Influenza volume',
            volumeWeight,
            0,
            1,
            (v) => updateTuning(() => volumeWeight = v),
          ),
          _slider(
            'Influenza bassi',
            bassWeight,
            0,
            1,
            (v) => updateTuning(() => bassWeight = v),
          ),
          _slider(
            'Influenza medi',
            midWeight,
            0,
            1,
            (v) => updateTuning(() => midWeight = v),
          ),
          _slider(
            'Influenza alti',
            trebleWeight,
            0,
            1,
            (v) => updateTuning(() => trebleWeight = v),
          ),
          _slider(
            'Spinta sul battito',
            beatBoost,
            0,
            1,
            (v) => updateTuning(() => beatBoost = v),
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
            'Parametri attivi: gain ${tuning.gain.toStringAsFixed(2)}, gate ${tuning.gate.toStringAsFixed(2)}, risposta V/B/M/A ${tuning.volumeWeight.toStringAsFixed(2)}/${tuning.bassWeight.toStringAsFixed(2)}/${tuning.midWeight.toStringAsFixed(2)}/${tuning.trebleWeight.toStringAsFixed(2)}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed:
                  source.isSupported &&
                      DeviceController.I.isConnected &&
                      !starting
                  ? toggleAudio
                  : null,
              child: Text(
                starting
                    ? 'Attendi…'
                    : (active ? 'Ferma audio' : 'Avvia audio del computer'),
              ),
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

  String _meter(double? value) =>
      value == null ? '—' : '${(value * 100).round()}%';
}
