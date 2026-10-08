import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/device_controller.dart';
import '../../core/services/android_audio_session.dart';
import '../../core/services/android_playback_audio_source.dart';
import '../../core/services/audio_feature_processor.dart';

class AudioFoundationPanel extends StatefulWidget {
  const AudioFoundationPanel({super.key});

  @override
  State<AudioFoundationPanel> createState() => _AudioFoundationPanelState();
}

class _AudioFoundationPanelState extends State<AudioFoundationPanel> {
  final session = AndroidAudioSession.I;
  double gain = 1, gate = .05, attack = .65, release = .3, min = 0, max = 1;
  double volumeWeight = .4;
  double bassWeight = .35;
  double midWeight = .15;
  double trebleWeight = .1;
  double beatBoost = .15;
  String? fallback;
  String? message;
  bool savingFallback = false;
  late final Future<List<String>> patterns;

  @override
  void initState() {
    super.initState();
    patterns = DeviceController.I.listPrograms();
    _applyTuning();
    unawaited(session.refreshAvailability());
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

  void _applyTuning() => session.updateTuning(tuning);

  Future<void> _start() async {
    setState(() => message = null);
    _applyTuning();
    try {
      await session.start();
    } catch (error) {
      if (mounted) setState(() => message = _friendlyError(error));
    }
  }

  Future<void> _stop() async {
    setState(() => message = null);
    try {
      await session.stop();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Audio fermato; la cupola risponderà alla protezione configurata.',
        );
      }
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString().replaceFirst(
      RegExp(r'^(StateError|Unsupported operation):\s*'),
      '',
    );
    if (text.contains('projection_denied')) {
      return 'Condivisione audio annullata.';
    }
    if (text.contains('record_audio_denied')) {
      return 'Autorizza l’audio nelle impostazioni Android e riprova.';
    }
    return text;
  }

  Future<void> _selectFallback(String? chosen) async {
    if (!DeviceController.I.isConnected) {
      setState(() => message = 'Connetti la cupola per applicare la scelta.');
      return;
    }
    setState(() => savingFallback = true);
    try {
      await DeviceController.I.setAudioFallback(chosen);
      if (mounted) {
        setState(() {
          fallback = chosen;
          message = chosen == null
              ? 'Se l’audio sparisce, la luce si spegnerà gradualmente.'
              : 'Se l’audio sparisce, partirà il pattern $chosen.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Non posso configurare il recupero. Verifica la connessione.',
        );
      }
    } finally {
      if (mounted) setState(() => savingFallback = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([session, DeviceController.I]),
      builder: (context, _) {
        final availability = session.availability;
        final supported = availability?.supported == true;
        final state = session.state;
        final features = session.features;
        final busy = state.status == AndroidAudioStatus.starting;
        return Card(
          child: ExpansionTile(
            leading: const Icon(Icons.graphic_eq_rounded),
            title: const Text('Audio del telefono'),
            subtitle: Text(
              session.platformCandidate
                  ? 'Android 10+ · reagisce alla musica riprodotta'
                  : 'Disponibile soltanto nell’app Android',
            ),
            childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(state.message),
                subtitle: Text(session.source.explanation),
                trailing: Chip(
                  label: Text(
                    session.checkingAvailability
                        ? 'Controllo…'
                        : state.status == AndroidAudioStatus.running
                        ? 'Attivo'
                        : supported
                        ? 'Pronto'
                        : 'Non disponibile',
                  ),
                ),
              ),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Android mostrerà una conferma a ogni avvio. Alcune app e i contenuti protetti da DRM possono trasmettere silenzio.',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _featureChip('Volume', features?.volume),
                  _featureChip('Bassi', features?.bass),
                  _featureChip('Medi', features?.mid),
                  _featureChip('Alti', features?.treble),
                  Chip(
                    label: Text(
                      'Battito ${features?.beat == true ? 'sì' : '—'}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _slider('Sensibilità', gain, 0, 3, (v) => gain = v),
              _slider('Soglia rumore', gate, 0, .5, (v) => gate = v),
              _slider('Reazione in salita', attack, 0, 1, (v) => attack = v),
              _slider('Ritorno alla calma', release, 0, 1, (v) => release = v),
              _slider('Luce minima', min, 0, .9, (v) => min = v.clamp(0, max)),
              _slider('Luce massima', max, .1, 1, (v) => max = v.clamp(min, 1)),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Risposta alle frequenze'),
              ),
              _slider(
                'Influenza volume',
                volumeWeight,
                0,
                1,
                (v) => volumeWeight = v,
              ),
              _slider(
                'Influenza bassi',
                bassWeight,
                0,
                1,
                (v) => bassWeight = v,
              ),
              _slider('Influenza medi', midWeight, 0, 1, (v) => midWeight = v),
              _slider(
                'Influenza alti',
                trebleWeight,
                0,
                1,
                (v) => trebleWeight = v,
              ),
              _slider(
                'Spinta sul battito',
                beatBoost,
                0,
                1,
                (v) => beatBoost = v,
              ),
              Text(
                'Se l’audio si interrompe, la cupola usa la dissolvenza o il pattern scelto qui sotto.',
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
                        : (choice) =>
                              _selectFallback(choice == '' ? null : choice),
                  );
                },
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: Text(message!)),
              ],
              const SizedBox(height: 12),
              if (session.platformCandidate && supported)
                SizedBox(
                  width: double.infinity,
                  child: state.status == AndroidAudioStatus.running
                      ? OutlinedButton.icon(
                          onPressed: _stop,
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('Ferma audio'),
                        )
                      : FilledButton.icon(
                          onPressed: busy || !DeviceController.I.isConnected
                              ? null
                              : _start,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(
                            DeviceController.I.isConnected
                                ? 'Avvia audio del telefono'
                                : 'Connetti prima la cupola',
                          ),
                        ),
                )
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    session.platformCandidate
                        ? 'Questo telefono usa Android ${availability?.sdk ?? '?'}: serve Android 10 o successivo.'
                        : 'Sul Web, iPhone e desktop questa funzione non viene proposta.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Chip _featureChip(String label, double? value) => Chip(
    label: Text('$label ${value == null ? '—' : '${(value * 100).round()}%'}'),
  );

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
        onChanged: (next) {
          setState(() => changed(next));
          _applyTuning();
        },
      ),
    ],
  );
}
