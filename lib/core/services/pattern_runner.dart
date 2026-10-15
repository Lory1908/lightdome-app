import 'dart:async';
import 'dart:math' as math;

import '../models/pattern.dart';
import '../api/device_api.dart';
import 'mic_reactive_service.dart';
import 'signal_monitor.dart';
import '../../controllers/device_controller.dart';

class PatternRunner {
  DeviceApi? _api;
  Timer? _timer;
  PatternConfig _cfg = const PatternConfig.none();
  double _t = 0; // seconds
  int _lastUs = 0; // timestamp for accurate dt
  bool _sending = false;
  double? _pending;
  final void Function(double y)? _onLocalY;
  final Future<void> Function(double y)? _onMicY;

  PatternRunner({
    DeviceApi? api,
    void Function(double y)? onLocalY,
    Future<void> Function(double y)? onMicY,
  }) : _api = api,
       _onLocalY = onLocalY,
       _onMicY = onMicY;
  MicReactiveService? _mic;

  void setApi(DeviceApi? api) {
    _api = api;
  }

  void restart(PatternConfig cfg) {
    stop();
    start(cfg);
  }

  void start(PatternConfig cfg) {
    _cfg = cfg;
    _t = 0;
    _timer?.cancel();
    // always stop mic stream when switching mode
    _mic?.stop();
    // Mic reactive uses mic stream instead of timer
    if (cfg.type == PatternType.micReactive) {
      _mic ??= MicReactiveService();
      _mic!.start(
        (lvl) async {
          var y = (cfg.offset + cfg.amplitude * lvl).clamp(0.0, 1.0);
          y = _applyGammaComp(y);
          SignalMonitor.I.pushTx(y);
          if (_api == null) {
            _onLocalY?.call(y);
          }
          _queueSend(y);
        },
        threshold: cfg.micThreshold ?? 0.05,
        attack: cfg.micAttack ?? 0.6,
        release: cfg.micRelease ?? 0.3,
      );
      return;
    }
    if (cfg.type == PatternType.none) return;
    // 60 Hz tick for smoothness, compute real dt
    _lastUs = DateTime.now().microsecondsSinceEpoch;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) async {
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      final dt = ((nowUs - _lastUs).clamp(0, 200000)) / 1e6; // cap dt to 0.2s
      _lastUs = nowUs;
      await _tick(dt);
    });
  }

  Future<void> _tick(double dt) async {
    _t += dt;
    var y = _applyGammaComp(_valueAt(_t).clamp(0.0, 1.0));
    SignalMonitor.I.pushTx(y);
    if (_api == null) {
      _onLocalY?.call(y);
    }
    _queueSend(y);
  }

  double _valueAt(double t) {
    switch (_cfg.type) {
      case PatternType.sine:
        final offset = _cfg.offset.clamp(0.0, 1.0);
        final amplitude = _cfg.amplitude.clamp(0.0, 1.0);
        final min = (offset - amplitude).clamp(0.0, 1.0);
        final max = (offset + amplitude).clamp(0.0, 1.0);
        final sine = math.sin(2 * math.pi * _cfg.freqHz * t);
        final norm = (sine + 1.0) * 0.5; // 0..1
        return min + (max - min) * norm;
      case PatternType.pulse:
        final freq = math.max(_cfg.freqHz, 0.05);
        final phase = (t * freq) % 1.0;
        final duty = (_cfg.duty ?? 0.5).clamp(0.05, 0.95);
        final low = _cfg.offset.clamp(0.0, 1.0);
        final high = (low + _cfg.amplitude).clamp(0.0, 1.0);
        const edge = 0.08;
        if (phase < duty) {
          final relative = phase / duty;
          if (relative < edge) {
            return _smoothStep(low, high, relative / edge);
          }
          if (relative > 1 - edge) {
            return _smoothStep(high, low, (relative - (1 - edge)) / edge);
          }
          return high;
        } else {
          final relative = (phase - duty) / (1 - duty);
          if (relative < edge) {
            return _smoothStep(high, low, relative / edge);
          }
          if (relative > 1 - edge) {
            return _smoothStep(low, high, (relative - (1 - edge)) / edge);
          }
          return low;
        }
      case PatternType.micReactive:
      case PatternType.songWaveSpotify:
      case PatternType.songWaveOpen:
        // Not implemented here (requires external providers/mic). Keep off.
        return 0.0;
      case PatternType.none:
        return 0.0;
    }
  }

  double _smoothStep(double start, double end, double progress) {
    final p = progress.clamp(0.0, 1.0);
    final eased = p * p * (3 - 2 * p);
    return start + (end - start) * eased;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _mic?.stop();
  }

  void dispose() {
    stop();
    _mic?.dispose();
    _mic = null;
  }

  double _applyGammaComp(double y) {
    if (_cfg.gammaComp != true) return y;
    final g = DeviceController.I.state.gamma;
    if (g <= 0.01) return y;
    return math.pow(y.clamp(0.0, 1.0), 1.0 / g).toDouble();
  }

  void _queueSend(double y) {
    _pending = y;
    if (_api == null) {
      return;
    }
    if (!_sending) _pump();
  }

  Future<void> _pump() async {
    if (_sending) return;
    if (_api == null) {
      _pending = null;
      return;
    }
    _sending = true;
    try {
      while (_pending != null) {
        final v = _pending!;
        _pending = null;
        try {
          if (_cfg.type == PatternType.micReactive && _onMicY != null) {
            await _onMicY(v);
          } else {
            await _api!.setY(v);
          }
        } catch (_) {}
        // small pacing to avoid flooding
        await Future.delayed(const Duration(milliseconds: 12));
      }
    } finally {
      _sending = false;
    }
  }
}
