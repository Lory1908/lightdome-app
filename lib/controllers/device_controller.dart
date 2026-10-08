import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api/device_api.dart';
import '../core/models/device_state.dart';
import '../core/services/live_stream_service.dart';
import '../core/services/state_poller.dart';
import '../core/persistence/prefs.dart';
import '../core/models/pattern.dart';
import '../core/models/pattern_draft.dart';
import '../core/services/pattern_runner.dart';
import '../core/services/envelope_builder.dart';
import '../core/ldy/ldy_encoder.dart';
import '../core/services/signal_monitor.dart';
import '../core/services/realtime_service.dart';
import '../core/services/device_directory.dart';

class DeviceController extends ChangeNotifier {
  static final DeviceController I = DeviceController._();
  DeviceController._();

  String _ip = '';
  DeviceApi? _api;
  LiveStreamService? _live;
  StatePoller? _poller;
  PatternRunner? _runner;
  RealtimeService? _realtime;

  DeviceState state = DeviceState.initial();
  PatternConfig _pattern = const PatternConfig.none();
  String? _fallbackProgram; // program name on device

  String get ip => _ip;
  bool get isConnected => state.connected;
  PatternConfig get pattern => _pattern;
  String? get fallbackProgram => _fallbackProgram;

  void setIp(String ip) {
    final next = ip.trim();
    if (next.isEmpty) {
      disconnect();
      return;
    }
    if (next == _ip && _api != null) {
      // Same device requested: just restart polling to recover from potential glitches.
      SignalMonitor.I.reset();
      state = DeviceState.initial();
      notifyListeners();
      unawaited(_realtime?.dispose());
      _realtime = null;
      final base = _ip.startsWith('http') ? _ip : 'http://$_ip';
      _attachRealtime(base);
      _poller?.start();
      unawaited(DeviceDirectory.I.markSeen(base));
      _runner ??= PatternRunner(api: _api, onLocalY: _handleLocalPatternY);
      _runner!.setApi(_api);
      if (_pattern.type != PatternType.none) {
        _runner!.restart(_pattern);
      }
      return;
    }
    _ip = next;
    final base = _ip.startsWith('http') ? _ip : 'http://$_ip';
    _poller?.stop();
    _live?.dispose();
    _runner?.dispose();
    unawaited(_realtime?.dispose());
    _realtime = null;
    _api = DeviceApi(base);
    _live = LiveStreamService(_api!);
    _runner = PatternRunner(api: _api, onLocalY: _handleLocalPatternY);
    _runner!.setApi(_api);
    SignalMonitor.I.reset();
    // Mark as connecting while we wait for the first poll.
    state = DeviceState.initial();
    notifyListeners();
    _poller = StatePoller(
      api: _api!,
      onUpdate: (s) {
        state = s;
        notifyListeners();
      },
      onOffline: () {
        state = state.copyWith(connected: false);
        notifyListeners();
      },
    )..start();
    _attachRealtime(base);
    // Persist for next launches
    unawaited(Prefs.setString('device_ip', _ip));
    unawaited(DeviceDirectory.I.addOrUpdate(base));
    // Re-apply saved pattern when (re)connecting
    if (_pattern.type != PatternType.none) {
      _runner?.start(_pattern);
    }
    notifyListeners();
  }

  void disconnect() {
    // If a fallback program is defined, attempt to start it before disconnecting
    final api = _api;
    final fb = _fallbackProgram;
    if (api != null && fb != null && fb.isNotEmpty) {
      // fire-and-forget
      unawaited(api.startProgram(fb).catchError((_) {}));
    }
    _poller?.stop();
    _poller = null;
    _live?.dispose();
    _live = null;
    _runner?.setApi(null);
    unawaited(_realtime?.dispose());
    _realtime = null;
    _api = null;
    state = DeviceState.initial();
    SignalMonitor.I.reset();
    notifyListeners();
  }

  void _attachRealtime(String baseUrl) {
    unawaited(() async {
      final svc = await RealtimeService.connect(
        baseUrl: baseUrl,
        onState: _handleRealtimeState,
        onTx: SignalMonitor.I.pushTx,
        onDisconnected: _handleRealtimeDisconnect,
      );
      if (svc == null) return;
      if (_api == null || _ip.isEmpty) {
        await svc.dispose();
        return;
      }
      _realtime = svc;
      _poller?.start(interval: const Duration(seconds: 1));
    }());
  }

  void _handleRealtimeState(DeviceState s) {
    if (_api == null) return;
    state = s;
    SignalMonitor.I.pushRx(s.y);
    notifyListeners();
  }

  void _handleRealtimeDisconnect() {
    _realtime = null;
    if (_api != null) {
      _poller?.start(interval: const Duration(milliseconds: 200));
    }
  }

  Future<void> refreshOnce() async {
    final api = _api;
    if (api == null) return;
    try {
      final st = await api.fetchState();
      if (st != null) {
        state = st;
      } else {
        state = state.copyWith(connected: false);
      }
    } catch (_) {
      state = state.copyWith(connected: false);
    }
    notifyListeners();
  }

  void sendY(double y01) {
    if (_live != null) {
      _live!.setY(y01);
    } else {
      SignalMonitor.I.pushTx(y01);
      SignalMonitor.I.pushRx(y01);
      state = state.copyWith(y: y01, on: y01 > 0, connected: false);
      notifyListeners();
    }
  }

  Future<void> off() async {
    await setPattern(const PatternConfig.none(), persist: false);
    try {
      await _api?.stopProgram();
    } catch (_) {}
    try {
      await _api?.stopRam();
    } catch (_) {}
    try {
      await _api?.off();
    } catch (_) {}
    if (_api == null) {
      SignalMonitor.I.pushTx(0);
      SignalMonitor.I.pushRx(0);
      state = DeviceState.initial();
      notifyListeners();
    }
    await refreshOnce();
  }

  Future<void> setParams({
    double? brightnessPct,
    double? gamma,
    bool? loop,
  }) async {
    try {
      await _api?.setParams(
        brightnessPct: brightnessPct,
        gamma: gamma,
        loop: loop,
      );
    } catch (_) {}
    await refreshOnce();
  }

  Future<List<String>> listPrograms() async {
    final api = _api;
    if (api == null) return [];
    return api.listPrograms();
  }

  Future<void> startProgram(String name) async {
    try {
      await _api?.startProgram(name);
    } catch (_) {}
    await refreshOnce();
  }

  Future<void> stopProgram() async {
    try {
      await _api?.stopProgram();
    } catch (_) {}
    await refreshOnce();
  }

  Future<void> deleteProgram(String name) async {
    try {
      await _api?.deleteProgram(name);
    } catch (_) {}
  }

  Future<void> uploadProgramStream({
    required String name,
    required Stream<List<int>> data,
    required int length,
    bool autorun = false,
    void Function(double progress)? onProgress,
  }) async {
    final api = _api;
    if (api == null) {
      throw Exception('Device non connesso');
    }
    await api.uploadProgramFile(
      name: name,
      data: data,
      length: length,
      autorun: autorun,
      onProgress: (sent, total) {
        if (onProgress != null && total > 0) {
          onProgress((sent / total).clamp(0.0, 1.0));
        }
      },
    );
    await refreshOnce();
  }

  Future<void> setAudioFallback(String? name) async {
    final api = _api;
    if (api == null) throw StateError('Cupola non connessa');
    await api.configureAudioFallback(name);
  }

  Future<void> sendAudioLevel(double level) async {
    final api = _api;
    if (api == null) throw StateError('Cupola non connessa');
    SignalMonitor.I.pushTx(level);
    await api.sendAudioY(level);
  }

  Future<void> finishAudioStream({String? fallback}) async {
    final api = _api;
    if (api == null) return;
    try {
      if (fallback != null && fallback.isNotEmpty) {
        await api.startProgram(fallback);
      } else {
        await api.stopAudio();
      }
    } catch (_) {
      // The firmware watchdog remains the final safety net if the LAN vanished.
    }
  }

  Future<PatternDraft?> loadProgramDraft(String name) async {
    final api = _api;
    if (api == null) throw StateError('Cupola non connessa');
    return api.fetchProgramDraft(name);
  }

  Future<void> saveGeneratedProgram({
    required String name,
    required int sampleRateHz,
    required List<int> samples,
    required PatternDraft draft,
    required bool loop,
    required bool autorun,
    bool start = true,
  }) async {
    final api = _api;
    if (api == null) {
      throw Exception('Cupola non connessa');
    }
    await api.setParams(loop: loop);
    final bytes = LdyEncoder.encode(
      sampleRateHz: sampleRateHz,
      y1023: samples,
      recipeMetadata: draft.toJson(),
    );
    await api.saveProgramLdy(
      name: name,
      bytes: bytes,
      sampleRateHz: sampleRateHz,
      autorun: autorun,
    );
    if (start) {
      await api.startProgram(name);
    }
    await refreshOnce();
  }

  // Pattern management
  Future<void> setPattern(PatternConfig cfg, {bool persist = true}) async {
    _pattern = cfg;
    if (persist) {
      await Prefs.setString('pattern_cfg', cfg.toJsonString());
    }
    _runner ??= PatternRunner(api: _api, onLocalY: _handleLocalPatternY);
    _runner!.setApi(_api);
    _runner!.stop();
    if (cfg.type != PatternType.none) {
      _runner!.start(cfg);
    }
    notifyListeners();
  }

  Future<void> setFallbackProgram(String? name) async {
    _fallbackProgram = (name == null || name.isEmpty) ? null : name;
    if (_fallbackProgram != null) {
      await Prefs.setString('fallback_program', _fallbackProgram!);
    } else {
      await Prefs.remove('fallback_program');
    }
    notifyListeners();
  }

  Future<void> restoreLastDevice() async {
    final saved = await Prefs.getString('device_ip');
    if (saved != null && saved.trim().isNotEmpty) {
      setIp(saved);
    }
    final p = await Prefs.getString('pattern_cfg');
    if (p != null) {
      try {
        _pattern = PatternConfig.fromJsonString(p);
      } catch (_) {
        _pattern = const PatternConfig.none();
      }
    }
    _fallbackProgram = await Prefs.getString('fallback_program');
    _runner ??= PatternRunner(api: _api, onLocalY: _handleLocalPatternY);
    _runner!.setApi(_api);
    if (_pattern.type != PatternType.none) {
      _runner!.start(_pattern);
    }
  }

  // Build and upload program from local audio file (open provider)
  Future<String?> buildAndUploadProgramFromFile({
    required String filePath,
    required String name,
    int sampleRateHz = 100,
    bool autorun = false,
  }) async {
    final api = _api;
    if (api == null) return null;
    final ys = await EnvelopeBuilder.fromAudioFile(
      path: filePath,
      sampleRateHz: sampleRateHz,
    );
    final bytes = LdyEncoder.encode(sampleRateHz: sampleRateHz, y1023: ys);
    final res = await api.saveProgramLdy(
      name: name,
      bytes: bytes,
      sampleRateHz: sampleRateHz,
      autorun: autorun,
    );
    return res;
  }

  void _handleLocalPatternY(double y) {
    if (_api != null) return;
    SignalMonitor.I.pushRx(y);
    state = state.copyWith(y: y, on: y > 0, connected: false);
    notifyListeners();
  }
}
