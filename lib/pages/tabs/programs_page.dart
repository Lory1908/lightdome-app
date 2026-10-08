import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controllers/device_controller.dart';
import '../../core/models/pattern.dart';
import '../../core/models/pattern_draft.dart';
import 'create_page.dart';

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
  double _threshold = .15;
  double _attack = .65;
  double _release = .3;

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
    );
    if (mounted) {
      setState(
        () => _message =
            'Microfono attivo. Questa modalità richiede che l’app resti aperta.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = DeviceController.I;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => ListView(
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
              leading: const Icon(Icons.graphic_eq_rounded),
              title: const Text('Audio reattivo'),
              subtitle: const Text('Usa il microfono di questo dispositivo'),
              childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              children: [
                _slider(
                  'Sensibilità',
                  _gain,
                  0,
                  2,
                  (value) => setState(() => _gain = value),
                ),
                _slider(
                  'Soglia rumore',
                  _threshold,
                  0,
                  .5,
                  (value) => setState(() => _threshold = value),
                ),
                _slider(
                  'Attack',
                  _attack,
                  .05,
                  1,
                  (value) => setState(() => _attack = value),
                ),
                _slider(
                  'Release',
                  _release,
                  .05,
                  1,
                  (value) => setState(() => _release = value),
                ),
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
                        onPressed: _startMic,
                        icon: const Icon(Icons.mic_rounded),
                        label: const Text('Avvia microfono'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => controller.setPattern(
                        const PatternConfig.none(),
                        persist: false,
                      ),
                      child: const Text('Ferma'),
                    ),
                  ],
                ),
              ],
            ),
          ),
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
                if (_uploading) LinearProgressIndicator(value: _uploadProgress),
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
      ),
    );
  }

  Widget _slider(
    String label,
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
        Slider(value: value, min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}
