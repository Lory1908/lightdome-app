import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../models/device_entry.dart';
import '../persistence/prefs.dart';

class DeviceDirectory extends ChangeNotifier {
  static final DeviceDirectory I = DeviceDirectory._();
  DeviceDirectory._();

  static const _prefsKey = 'device_directory';
  static const _discoveryChannel = MethodChannel(
    'lightdome/network_discovery',
  );

  final List<DeviceEntry> _saved = [];
  final List<DeviceEntry> _discovered = [];
  bool _discovering = false;

  List<DeviceEntry> get saved => List.unmodifiable(_saved);
  List<DeviceEntry> get discovered => List.unmodifiable(_discovered);
  bool get discovering => _discovering;

  Future<void> restore() async {
    final raw = await Prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List;
      _saved
        ..clear()
        ..addAll(decoded
            .whereType<Map<String, dynamic>>()
            .map(DeviceEntry.fromJson)
            .where((e) => e.baseUrl.isNotEmpty));
      _saved.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
      notifyListeners();
    } catch (_) {
      // Ignore corrupted data.
    }
  }

  Future<void> _persist() async {
    final json = jsonEncode(_saved.map((e) => e.copyWith(discovered: false).toJson()).toList());
    await Prefs.setString(_prefsKey, json);
  }

  Future<void> addOrUpdate(String baseUrl, {String? label}) async {
    final normalized = _normalizeBase(baseUrl);
    if (normalized.isEmpty) return;
    final now = DateTime.now();
    final idx = _saved.indexWhere((e) => e.baseUrl == normalized);
    final display = label?.trim().isNotEmpty == true ? label!.trim() : _friendlyLabelFromUrl(normalized);
    if (idx >= 0) {
      _saved[idx] = _saved[idx].copyWith(
        label: display,
        lastSeen: now,
        discovered: false,
      );
    } else {
      _saved.add(DeviceEntry(baseUrl: normalized, label: display, lastSeen: now));
    }
    _saved.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String baseUrl) async {
    final normalized = _normalizeBase(baseUrl);
    _saved.removeWhere((e) => e.baseUrl == normalized);
    await _persist();
    notifyListeners();
  }

  Future<void> markSeen(String baseUrl) async {
    final normalized = _normalizeBase(baseUrl);
    final idx = _saved.indexWhere((e) => e.baseUrl == normalized);
    if (idx >= 0) {
      _saved[idx] = _saved[idx].copyWith(lastSeen: DateTime.now());
      _saved.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
      await _persist();
      notifyListeners();
    }
  }

  Future<void> discover({Duration timeout = const Duration(seconds: 4)}) async {
    if (kIsWeb || _discovering) {
      return;
    }
    _discovering = true;
    notifyListeners();

    final mdns = MDnsClient();
    final Map<String, DeviceEntry> found = {};
    final needsAndroidMulticastLock =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

    try {
      if (needsAndroidMulticastLock) {
        await _discoveryChannel.invokeMethod<void>('acquireMulticastLock');
      }
      await mdns.start();
      final ptrStream = mdns.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer('_http._tcp.local'));
      final ptrSub = ptrStream.listen((ptr) {
        final service = ptr.domainName.toLowerCase();
        if (!service.contains('cupola') && !service.contains('lightdome') && !service.contains('led')) {
          return;
        }
        mdns.lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName)).listen((srv) {
          final target = _cleanHost(srv.target);
          final base = _buildBaseUrl(target, srv.port);
          final label = _friendlyLabelFromName(ptr.domainName) ?? _friendlyLabelFromUrl(base);
          found[base] = DeviceEntry(
            baseUrl: base,
            label: label,
            lastSeen: DateTime.now(),
            discovered: true,
          );
        });
      }, onError: (_) {});

      await Future.delayed(timeout);
      await ptrSub.cancel();
    } catch (_) {
      // Discovery failure is non-fatal.
    } finally {
      mdns.stop();
      if (needsAndroidMulticastLock) {
        try {
          await _discoveryChannel.invokeMethod<void>('releaseMulticastLock');
        } catch (_) {}
      }
      _discovering = false;
    }

    if (found.isNotEmpty) {
      final merged = found.values.toList();
      merged.sort((a, b) => a.label.compareTo(b.label));
      _discovered
        ..clear()
        ..addAll(merged);
    } else {
      _discovered.clear();
    }
    notifyListeners();
  }

  void clearDiscovered() {
    if (_discovered.isEmpty) return;
    _discovered.clear();
    notifyListeners();
  }

  static String _normalizeBase(String input) {
    if (input.isEmpty) return '';
    var value = input.trim();
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static String _buildBaseUrl(String host, int port) {
    final normalizedHost = _cleanHost(host);
    if (port == 80 || port == 0) {
      return 'http://$normalizedHost';
    }
    return 'http://$normalizedHost:$port';
  }

  static String _cleanHost(String host) {
    var h = host.trim();
    if (h.endsWith('.')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  static String _friendlyLabelFromUrl(String base) {
    try {
      final uri = Uri.parse(base);
      if (uri.host.isNotEmpty) {
        return uri.host;
      }
    } catch (_) {}
    return base;
  }

  static String? _friendlyLabelFromName(String name) {
    final parts = name.split('.');
    if (parts.isEmpty) return null;
    final raw = parts.firstWhere((p) => p.isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return null;
    return raw.replaceAll('-', ' ');
  }
}
