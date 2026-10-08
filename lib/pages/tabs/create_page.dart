import 'package:flutter/material.dart';

import '../../controllers/device_controller.dart';
import '../../core/models/pattern_recipe.dart';

class CreatePage extends StatefulWidget {
  const CreatePage({super.key});

  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> {
  final _name = TextEditingController(text: 'respiro');
  PatternRecipeType _type = PatternRecipeType.breath;
  PatternEasing _easing = PatternEasing.smooth;
  double _duration = 4;
  double _minimum = .08;
  double _maximum = 1;
  double _duty = .5;
  double _randomness = .2;
  bool _loop = true;
  bool _autorun = false;
  bool _saving = false;
  String? _message;
  bool _error = false;

  PatternRecipe get _recipe => PatternRecipe(
    type: _type,
    durationSeconds: _duration,
    minimum: _minimum,
    maximum: _maximum,
    duty: _duty,
    easing: _easing,
    randomness: _randomness,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _select(PatternRecipeType type) {
    setState(() {
      _type = type;
      switch (type) {
        case PatternRecipeType.breath:
          _name.text = 'respiro';
          _duration = 4;
          _minimum = .08;
          _maximum = 1;
          _duty = .5;
          _easing = PatternEasing.smooth;
          break;
        case PatternRecipeType.pulse:
          _name.text = 'battito';
          _duration = 1.4;
          _minimum = .05;
          _maximum = 1;
          _duty = .35;
          _easing = PatternEasing.sharp;
          break;
        case PatternRecipeType.sunrise:
          _name.text = 'alba';
          _duration = 12;
          _minimum = .02;
          _maximum = 1;
          _duty = .8;
          _easing = PatternEasing.natural;
          break;
        case PatternRecipeType.organic:
          _name.text = 'organico';
          _duration = 6;
          _minimum = .18;
          _maximum = .82;
          _duty = .5;
          _easing = PatternEasing.smooth;
          break;
      }
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(name)) {
      setState(() {
        _error = true;
        _message = 'Usa lettere, numeri, trattino o underscore.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = false;
      _message = 'Salvataggio nella cupola…';
    });
    try {
      await DeviceController.I.saveGeneratedProgram(
        name: name,
        sampleRateHz: _recipe.sampleRateHz,
        samples: _recipe.render(),
        loop: _loop,
        autorun: _autorun,
      );
      if (!mounted) return;
      setState(
        () => _message =
            'Pattern salvato e avviato. Continuerà anche chiudendo l’app.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _message = 'Non sono riuscito a salvare il pattern.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      children: [
        Text(
          'Crea un’atmosfera',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 5),
        Text(
          'Parti da un’idea semplice. LightDome la trasforma in un pattern autonomo.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Scegli uno stile',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 13),
                Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: [
                    _preset(
                      PatternRecipeType.breath,
                      'Respiro',
                      'Morbido e continuo',
                    ),
                    _preset(
                      PatternRecipeType.pulse,
                      'Battito',
                      'Ritmico e definito',
                    ),
                    _preset(
                      PatternRecipeType.sunrise,
                      'Alba',
                      'Crescita lenta',
                    ),
                    _preset(
                      PatternRecipeType.organic,
                      'Organico',
                      'Variazioni naturali',
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Nome del pattern',
                    helperText: 'Verrà salvato direttamente nella cupola.',
                  ),
                ),
                const SizedBox(height: 18),
                AspectRatio(
                  aspectRatio: 3.2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: CustomPaint(
                        painter: _RecipePainter(_recipe, scheme),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _slider(
                  'Durata del ciclo',
                  '${_duration.toStringAsFixed(1)} s',
                  _duration,
                  1,
                  20,
                  (value) => setState(() => _duration = value),
                ),
                _slider(
                  'Luce minima',
                  '${(_minimum * 100).round()}%',
                  _minimum,
                  0,
                  .9,
                  (value) => setState(() {
                    _minimum = value.clamp(0, _maximum);
                  }),
                ),
                _slider(
                  'Luce massima',
                  '${(_maximum * 100).round()}%',
                  _maximum,
                  .1,
                  1,
                  (value) => setState(() {
                    _maximum = value.clamp(_minimum, 1);
                  }),
                ),
                if (_type == PatternRecipeType.pulse)
                  _slider(
                    'Tempo acceso',
                    '${(_duty * 100).round()}%',
                    _duty,
                    .05,
                    .95,
                    (value) => setState(() => _duty = value),
                  ),
                if (_type == PatternRecipeType.organic)
                  _slider(
                    'Irregolarità',
                    '${(_randomness * 100).round()}%',
                    _randomness,
                    0,
                    1,
                    (value) => setState(() => _randomness = value),
                  ),
                Text(
                  _type == PatternRecipeType.organic
                      ? 'Indica quanto il movimento varia invece di ripetersi sempre uguale.'
                      : 'Qualità alta · 150 aggiornamenti al secondo, scelta automaticamente.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                DropdownButtonFormField<PatternEasing>(
                  initialValue: _easing,
                  decoration: const InputDecoration(labelText: 'Movimento'),
                  items: const [
                    DropdownMenuItem(
                      value: PatternEasing.smooth,
                      child: Text('Morbido'),
                    ),
                    DropdownMenuItem(
                      value: PatternEasing.natural,
                      child: Text('Naturale'),
                    ),
                    DropdownMenuItem(
                      value: PatternEasing.linear,
                      child: Text('Lineare'),
                    ),
                    DropdownMenuItem(
                      value: PatternEasing.sharp,
                      child: Text('Netto'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _easing = value);
                  },
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Continua finché non lo fermo'),
                  subtitle: const Text(
                    'Funziona anche quando app e sito sono chiusi.',
                  ),
                  value: _loop,
                  onChanged: (value) => setState(() => _loop = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Riparti dopo uno spegnimento'),
                  subtitle: const Text('Imposta questo pattern come autorun.'),
                  value: _autorun,
                  onChanged: (value) => setState(() => _autorun = value),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_saving ? 'Salvataggio…' : 'Salva e avvia'),
                  ),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: (_error ? scheme.error : scheme.secondary)
                          .withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(13),
                      child: Row(
                        children: [
                          Icon(
                            _error
                                ? Icons.error_outline_rounded
                                : Icons.check_circle_outline_rounded,
                            color: _error ? scheme.error : scheme.secondary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(_message!)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.graphic_eq_rounded),
            title: const Text('Audio reattivo'),
            subtitle: const Text(
              'Microfono e audio di sistema useranno bassi, medi, alti, soglia, attack e release. La sorgente deve restare attiva.',
            ),
            trailing: const Chip(label: Text('Prossimo passo')),
          ),
        ),
      ],
    );
  }

  Widget _preset(PatternRecipeType type, String title, String subtitle) {
    final selected = _type == type;
    return SizedBox(
      width: 155,
      child: ChoiceChip(
        selected: selected,
        onSelected: (_) => _select(type),
        label: SizedBox(
          width: 125,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(subtitle, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slider(
    String label,
    String value,
    double current,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Row(
            children: [
              Text(label),
              const Spacer(),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(value: current, min: min, max: max, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _RecipePainter extends CustomPainter {
  const _RecipePainter(this.recipe, this.scheme);

  final PatternRecipe recipe;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final path = Path();
    for (var i = 0; i <= 100; i++) {
      final x = size.width * i / 100;
      final y = size.height - recipe.valueAt(i / 100) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = scheme.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RecipePainter oldDelegate) => true;
}
