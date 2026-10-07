import 'dart:async';
import 'dart:convert';

import '../models/device_state.dart';
import '../models/wifi_config.dart';
import 'http_client.dart';

class DeviceApi {
  final String base; // e.g. http://192.168.1.50
  const DeviceApi(this.base);

  String _u(String path) => base.endsWith('/')
      ? '${base.substring(0, base.length - 1)}$path'
      : '$base$path';

  Future<DeviceState?> fetchState() async {
    try {
      final j = await getJson(_u('/api/state'));
      return DeviceState.fromApiJson(j);
    } catch (_) {
      try {
        final j = await getJson(_u('/status'));
        return DeviceState.fromStatusJson(j);
      } catch (e) {
        return null;
      }
    }
  }

  Future<void> setY(double y01) async {
    // Prefer legacy GET /set for immediate response and compatibility
    final y1023 = (y01.clamp(0.0, 1.0) * 1023).round();
    await getText(_u('/set?y=$y1023&smooth=90'));
  }

  Future<void> off() async {
    await getText(_u('/set?y=0'));
  }

  Future<void> setParams({
    double? brightnessPct,
    double? gamma,
    bool? loop,
  }) async {
    final q = <String, String>{};
    if (brightnessPct != null) {
      q['brightness'] = brightnessPct.clamp(0, 100).toStringAsFixed(0);
    }
    if (gamma != null) q['gamma'] = gamma.clamp(1.0, 3.0).toStringAsFixed(1);
    if (loop != null) q['loop'] = loop ? '1' : '0';
    if (q.isEmpty) {
      return;
    }
    final qs = q.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    await getText(_u('/params?$qs'));
  }

  // Programs (basic)
  Future<List<String>> listPrograms() async {
    try {
      final txt = await getText(_u('/prog/list'));
      final lines = const LineSplitter().convert(txt);
      return lines
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && e != '(vuoto)')
          .map((e) => e.replaceAll('.ldy', '').split(' ').first)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> startProgram(String name) async {
    await postJson(_u('/prog/start?name=${Uri.encodeComponent(name)}'), {});
  }

  Future<void> stopProgram() async {
    await postJson(_u('/prog/stop'), {});
  }

  Future<void> deleteProgram(String name) async {
    await deleteText(_u('/prog/delete?name=${Uri.encodeComponent(name)}'));
  }

  Future<WifiSetupStatus> wifiStatus() async {
    final json = await getJson(
      _u('/wifi/status'),
      timeout: const Duration(seconds: 5),
    );
    return WifiSetupStatus.fromJson(json);
  }

  Future<List<WifiNetwork>> scanWifi() async {
    final json = await getJson(
      _u('/wifi/scan'),
      timeout: const Duration(seconds: 20),
    );
    final raw = json['networks'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => WifiNetwork.fromJson(Map<String, dynamic>.from(item)))
        .where((network) => network.ssid.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> configureWifi({
    required String ssid,
    required String password,
  }) async {
    await postJson(_u('/wifi/config'), {
      'ssid': ssid,
      'password': password,
    }, timeout: const Duration(seconds: 10));
  }

  // Pattern RAM (compat)
  Future<String> uploadPatternText(String text) async {
    return postBytes(
      _u('/pattern'),
      utf8.encode(text),
      headers: {'Content-Type': 'text/plain'},
    );
  }

  Future<void> playRam() async {
    await postJson(_u('/play'), {});
  }

  Future<void> stopRam() async {
    await postJson(_u('/stop'), {});
  }

  // Save LDY program to device (LittleFS)
  Future<String> saveProgramLdy({
    required String name,
    required List<int> bytes,
    int sampleRateHz = 100,
    bool autorun = false,
  }) async {
    final qs =
        'name=${Uri.encodeComponent(name)}&sr=$sampleRateHz&autorun=${autorun ? 1 : 0}';
    return postMultipartBytes(_u('/prog/save?$qs'), bytes);
  }

  Future<String> uploadProgramFile({
    required String name,
    required Stream<List<int>> data,
    required int length,
    bool autorun = false,
    void Function(int sent, int total)? onProgress,
  }) {
    final qs =
        'name=${Uri.encodeComponent(name)}&sr=0&autorun=${autorun ? 1 : 0}';
    return postMultipartStream(
      _u('/prog/save?$qs'),
      data,
      contentLength: length,
      timeout: const Duration(seconds: 30),
      onProgress: onProgress,
    );
  }
}
