class WifiNetwork {
  final String ssid;
  final int rssi;
  final bool secure;

  const WifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.secure,
  });

  factory WifiNetwork.fromJson(Map<String, dynamic> json) {
    return WifiNetwork(
      ssid: json['ssid']?.toString() ?? '',
      rssi: (json['rssi'] as num?)?.toInt() ?? -100,
      secure: json['secure'] == true,
    );
  }
}

class WifiSetupStatus {
  final bool configured;
  final bool connected;
  final bool portal;
  final String mode;
  final String ssid;
  final String ip;
  final String hostname;

  const WifiSetupStatus({
    required this.configured,
    required this.connected,
    required this.portal,
    required this.mode,
    required this.ssid,
    required this.ip,
    required this.hostname,
  });

  factory WifiSetupStatus.fromJson(Map<String, dynamic> json) {
    return WifiSetupStatus(
      configured: json['configured'] == true,
      connected: json['connected'] == true,
      portal: json['portal'] == true,
      mode: json['mode']?.toString() ?? '',
      ssid: json['ssid']?.toString() ?? '',
      ip: json['ip']?.toString() ?? '',
      hostname: json['hostname']?.toString() ?? 'lightdome.local',
    );
  }
}
