import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightdome_app/core/api/device_api.dart';
import 'package:lightdome_app/core/models/wifi_config.dart';

void main() {
  test('parses a scanned Wi-Fi network', () {
    final network = WifiNetwork.fromJson({
      'ssid': 'Studio',
      'rssi': -48,
      'secure': true,
    });

    expect(network.ssid, 'Studio');
    expect(network.rssi, -48);
    expect(network.secure, isTrue);
  });

  test('parses setup status without any password field', () {
    final status = WifiSetupStatus.fromJson({
      'configured': true,
      'connected': false,
      'portal': true,
      'mode': 'setup',
      'ssid': 'Studio',
      'ip': '192.168.4.1',
      'hostname': 'lightdome.local',
    });

    expect(status.configured, isTrue);
    expect(status.connected, isFalse);
    expect(status.portal, isTrue);
    expect(status.ssid, 'Studio');
    expect(status.hostname, 'lightdome.local');
  });

  test('sends Wi-Fi credentials with a fixed JSON content length', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late final HttpRequest received;
    late final String body;
    final handled = server.first.then((request) async {
      received = request;
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = HttpStatus.accepted
        ..headers.contentType = ContentType.json
        ..write('{"accepted":true}');
      await request.response.close();
    });

    try {
      await DeviceApi(
        'http://${server.address.address}:${server.port}',
      ).configureWifi(ssid: 'Studio', password: 'password123');
      await handled;

      expect(received.method, 'POST');
      expect(received.uri.path, '/wifi/config');
      expect(received.headers.contentType?.mimeType, 'application/json');
      expect(received.contentLength, utf8.encode(body).length);
      expect(jsonDecode(body), {'ssid': 'Studio', 'password': 'password123'});
    } finally {
      await server.close(force: true);
    }
  });
}
