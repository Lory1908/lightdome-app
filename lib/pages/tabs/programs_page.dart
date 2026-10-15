import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controllers/device_controller.dart';
import '../../core/models/pattern.dart';
import '../../core/models/pattern_draft.dart';
import 'create_page.dart';
import 'audio_foundation_panel.dart';

class ProgramsPage extends StatefulWidget {
  const ProgramsPage({super.key});

  @override
  State<ProgramsPage> createState() => _ProgramsPageState();
}

class _ProgramsPageState extends State<ProgramsPage> {
  final _name = TextEditingController();
  List<String> _programs = const [];
  bool _loading = false;
  String? _message;
  PlatformFile? _file;
  bool _autorun = false;
  double _uploadProgress = 0;
  bool _uploading = false;
  double _gain = 1;
  double _threshold = .02;
  double _attack = .65;
  double _release = .3;
  bool _micSettingsDirty = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final items = await DeviceController.I.listPrograms();
    if (!mounted) return;
    setState(() {
      _programs = items;
      _loading = false;
    });
  }

  Future<void> _edit(String name) async {
    try {
      final metadata = await DeviceController.I.loadProgramDraft(name);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text('Modifica $name')),
            body: CreatePage(
              editName: name,
              initialDraft: metadata ?? PatternDraft.legacy(name),
              guessed: metadata == null,
            ),
          ),
        ),
      );
      if (mounted) await _refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Impossibile leggere i parametri dalla cupola. Riprova quando è connessa.',
        );
      }
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ldy'],
      withData: kIsWeb,
      withReadStream: !kIsWeb,
    );
    if (!mounted || result == null || result.files.isEmpty) return;
    final selected = result.files.single;
    setState(() {
      _file = selected;
      _name.text = selected.name.replaceFirst(
        RegExp(r'\.ldy$', caseSensitive: false),
        '',
      );
      _message = null;
    });
  }

  Future<void> _upload() async {
    final file = _file;
    final name = _name.text.trim();
    if (file == null || !RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(name)) {
      setState(() => _message = 'Scegli un file e usa un nome valido.');
      return;
    }
    final bytes = file.bytes;
    final length = bytes?.length ?? file.size;
    final stream =
        file.readStream ?? (bytes == null ? null : Stream.value(bytes));
    if (stream == null || length <= 0) {
      setState(() => _message = 'Non riesco a leggere questo file.');
      return;
    }
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _message = 'Caricamento nella cupola…';
    });
    try {
      await DeviceController.I.uploadProgramStream(
        name: name,
        data: stream,
        length: length,
        autorun: _autorun,
        onProgress: (value) {
          if (mounted) setState(() => _uploadProgress = value);
        },
      );
      if (!mounted) return;
      setState(() => _message = 'Pattern importato correttamente.');
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _message = 'Importazione non riuscita.');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _startMic() async {
    await DeviceController.I.setPattern(
      PatternConfig(
        type: PatternType.micReactive,
        amplitude: _gain,
        micThreshold: _threshold,
        micAttack: _attack,
        micRelease: _release,
        gammaComp: true,
      ),
      persist: false,
    );
    if (mounted) {
      setState(() {
        _micSettingsDirty = false;
        _message =
            'Microfono attivo. Questa modalità richiede che l’app resti aperta.';
      });
    }
  }

  Future<void> _stopMic() async {
    await DeviceController.I.setPattern(
      const PatternConfig.none(),
      persist: false,
    );
    if (mounted) {
      setState(() => _message = 'Microfono fermato.');
    }
  }

  void _resetMicControls() {
    setState(() {
      _gain = 1;
      _threshold = .02;
      _attack = .65;
      _release = .3;
      _micSettingsDirty = true;
    });
  }

  void _changeMicSetting(VoidCallback change) {
    setState(() {
      change();
      _micSettingsDirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = DeviceController.I;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final micActive = controller.pattern.type == PatternType.micReactive;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'I tuoi pattern',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Vivono nella cupola e continuano senza telefono.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Aggiorna',
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (_loading) const LinearProgressIndicator(),
            if (!_loading && _programs.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(26),
                  child: Column(
                    children: [
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 38,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'La libreria è vuota',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Apri “Crea” per costruire il primo pattern.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            for (final program in _programs) ...[
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 7,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: scheme.primary.withValues(alpha: .13),
                    child: Icon(Icons.waves_rounded, color: scheme.primary),
                  ),
                  title: Text(
                    program,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    controller.state.programName == program
                        ? 'In esecuzione nella cupola'
                        : 'Disponibile offline',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Modifica',
                        onPressed: () => _edit(program),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Avvia',
                        onPressed: () => controller.startProgram(program),
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                      IconButton(
                        tooltip: 'Elimina',
                        onPressed: () async {
                          await controller.deleteProgram(program);
                          await _refresh();
                        },
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 9),
            ],
            Card(
              child: ExpansionTile(
                leading: Icon(
                  micActive ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: micActive ? scheme.primary : null,
                ),
                title: const Text('Audio reattivo'),
                subtitle: Text(
                  micActive
                      ? 'Microfono attivo · in ascolto'
                      : 'Usa il microfono del telefono',
                ),
                childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: micActive
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          micActive
                              ? Icons.hearing_rounded
                              : Icons.pause_circle_outline_rounded,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            micActive
                                ? 'In ascolto: la luce sta seguendo i suoni intorno al telefono.'
                                : 'Fermo: premi Avvia microfono per iniziare.',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _slider(
                    'Sensibilità',
                    'Quanto amplifica i suoni. Alzala se la luce reagisce poco.',
                    _gain,
                    0,
                    2,
                    (value) => _changeMicSetting(() => _gain = value),
                  ),
                  _slider(
                    'Soglia rumore',
                    'Ignora i rumori più deboli. Alzala se reagisce anche nel silenzio.',
                    _threshold,
                    0,
                    .15,
                    (value) => _changeMicSetting(() => _threshold = value),
                  ),
                  _slider(
                    'Reazione',
                    'Velocità con cui la luce sale quando arriva un suono.',
                    _attack,
                    .05,
                    1,
                    (value) => _changeMicSetting(() => _attack = value),
                  ),
                  _slider(
                    'Ritorno',
                    'Velocità con cui la luce scende quando il suono finisce.',
                    _release,
                    .05,
                    1,
                    (value) => _changeMicSetting(() => _release = value),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _resetMicControls,
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('Ripristina valori consigliati'),
                    ),
                  ),
                  if (micActive && _micSettingsDirty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Hai modificato i valori: premi Applica modifiche.',
                        style: TextStyle(color: scheme.primary),
                      ),
                    ),
                  ],
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'La modalità audio live si interrompe chiudendo l’app. I pattern salvati non hanno questa limitazione.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: micActive
                              ? (_micSettingsDirty ? _startMic : _stopMic)
                              : _startMic,
                          icon: Icon(
                            micActive && !_micSettingsDirty
                                ? Icons.stop_rounded
                                : Icons.mic_rounded,
                          ),
                          label: Text(
                            micActive
                                ? _micSettingsDirty
                                      ? 'Applica modifiche'
                                      : 'Ferma microfono'
                                : 'Avvia microfono',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 9),
            const AudioFoundationPanel(),
            const SizedBox(height: 9),
            Card(
              child: ExpansionTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('Importa file .ldy'),
                subtitle: const Text('Per pattern creati fuori dall’app'),
                childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                children: [
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Nome'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _uploading ? null : _pickFile,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: Text(_file?.name ?? 'Scegli file'),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Avvia dopo ogni riaccensione'),
                    value: _autorun,
                    onChanged: _uploading
                        ? null
                        : (value) => setState(() => _autorun = value),
                  ),
                  if (_uploading)
                    LinearProgressIndicator(value: _uploadProgress),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _uploading ? null : _upload,
                      icon: const Icon(Icons.save_alt_rounded),
                      label: const Text('Importa nella cupola'),
                    ),
                  ),
                ],
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Card(
                color: scheme.secondary.withValues(alpha: .1),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(_message!),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _slider(
    String label,
    String description,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      children: [
        Row(
          children: [
            Text(label),
            const Spacer(),
            Text(
              value.toStringAsFixed(2),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            description,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Slider(value: value, min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}
