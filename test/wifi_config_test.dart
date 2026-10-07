import 'package:flutter_test/flutter_test.dart';
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
}
