import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../controllers/device_controller.dart';
import '../../core/api/device_api.dart';
import '../../core/models/wifi_config.dart';
import '../../core/services/app_settings.dart';
import '../../core/services/device_directory.dart';
import '../../core/models/device_entry.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _ipCtrl = TextEditingController();
  final _wifiSsidCtrl = TextEditingController();
  final _wifiPasswordCtrl = TextEditingController();
  List<WifiNetwork> _wifiNetworks = const [];
  String? _selectedWifiSsid;
  bool _wifiBusy = false;
  bool _showWifiPassword = false;
  String _wifiMessage =
      'Prima collegati alla rete “LightDome-Setup”, poi cerca la rete di casa.';

  @override
  void initState() {
    super.initState();
    _ipCtrl.text = DeviceController.I.ip;
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _wifiSsidCtrl.dispose();
    _wifiPasswordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = DeviceController.I;
    final app = AppSettings.I;
    final directory = DeviceDirectory.I;
    return AnimatedBuilder(
      animation: Listenable.merge([ctrl, app, directory]),
      builder: (context, _) {
        final saved = directory.saved;
        final discovered = directory.discovered;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _connectionCard(context, ctrl, directory),
            const SizedBox(height: 12),
            _wifiSetupCard(),
            const SizedBox(height: 12),
            if (saved.isNotEmpty)
              _savedDevicesCard(context, saved, ctrl, directory),
            if (saved.isNotEmpty) const SizedBox(height: 12),
            _discoverCard(context, directory, discovered, ctrl),
            const SizedBox(height: 12),
            _preferencesCard(app),
            const SizedBox(height: 12),
            _notesCard(),
          ],
        );
      },
    );
  }

  Widget _connectionCard(
    BuildContext context,
    DeviceController ctrl,
    DeviceDirectory directory,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connessione',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ipCtrl,
              decoration: const InputDecoration(
                labelText: 'Indirizzo IP o lightdome.local',
                hintText: 'es. 192.168.1.50 oppure http://lightdome.local',
              ),
              onSubmitted: (v) => ctrl.setIp(v.trim()),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    final ip = _ipCtrl.text.trim();
                    ctrl.setIp(ip);
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('Connetti'),
                ),
                OutlinedButton.icon(
                  onPressed: ctrl.disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnetti'),
                ),
                if (!kIsWeb)
                  OutlinedButton.icon(
                    onPressed: directory.discovering ? null : _runDiscovery,
                    icon: const Icon(Icons.wifi_tethering),
                    label: Text(
                      directory.discovering
                          ? 'Scanner in corso...'
                          : 'Scansione rete',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              kIsWeb
                  ? 'Nel browser inserisci lightdome.local o l’indirizzo IP della cupola. Alcuni browser potrebbero chiedere accesso alla rete locale.'
                  : 'Puoi cercare i dispositivi o inserire l’indirizzo manualmente. L’ultimo indirizzo viene ricordato.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _wifiSetupCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Configura il Wi-Fi della cupola',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '1. Apri le impostazioni Wi-Fi del telefono o PC e collegati a '
              '“LightDome-Setup”.\n'
              '2. Torna qui, scegli la rete di casa e inserisci la password.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _wifiBusy ? null : _scanWifiNetworks,
              icon: const Icon(Icons.wifi_find),
              label: const Text('Cerca reti Wi-Fi'),
            ),
            if (_wifiNetworks.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Reti trovate',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              for (final network in _wifiNetworks.take(8)) ...[
                _wifiNetworkTile(network),
                const SizedBox(height: 7),
              ],
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _wifiSsidCtrl,
              enabled: !_wifiBusy,
              maxLength: 32,
              decoration: const InputDecoration(
                labelText: 'Nome rete Wi-Fi',
                hintText: 'SSID',
              ),
            ),
            TextField(
              controller: _wifiPasswordCtrl,
              enabled: !_wifiBusy,
              obscureText: !_showWifiPassword,
              maxLength: 63,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Password Wi-Fi',
                helperText: 'Può restare vuota solo per una rete aperta.',
                suffixIcon: IconButton(
                  tooltip: _showWifiPassword
                      ? 'Nascondi password'
                      : 'Mostra password',
                  onPressed: _wifiBusy
                      ? null
                      : () => setState(
                          () => _showWifiPassword = !_showWifiPassword,
                        ),
                  icon: Icon(
                    _showWifiPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _wifiBusy ? null : _configureWifi,
              icon: const Icon(Icons.save),
              label: const Text('Salva e collega'),
            ),
            const SizedBox(height: 10),
            if (_wifiBusy) const LinearProgressIndicator(),
            if (_wifiBusy) const SizedBox(height: 8),
            Text(_wifiMessage),
            const SizedBox(height: 6),
            const Text(
              'Dopo il salvataggio la scheda si riavvia. La password non viene '
              'salvata nell’app e non viene mostrata dalla scheda.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wifiNetworkTile(WifiNetwork network) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedWifiSsid == network.ssid;
    final quality = network.rssi >= -55
        ? 'Segnale ottimo'
        : network.rssi >= -68
        ? 'Segnale buono'
        : 'Segnale debole';
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.12)
          : scheme.surfaceContainerHigh.withValues(alpha: 0.66),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _wifiBusy
            ? null
            : () {
                setState(() => _selectedWifiSsid = network.ssid);
                _wifiSsidCtrl.text = network.ssid;
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                network.rssi >= -55
                    ? Icons.signal_wifi_4_bar_rounded
                    : network.rssi >= -68
                    ? Icons.network_wifi_3_bar_rounded
                    : Icons.network_wifi_1_bar_rounded,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      network.ssid,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$quality • ${network.rssi} dBm',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                network.secure
                    ? Icons.lock_outline_rounded
                    : Icons.lock_open_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: selected ? scheme.primary : scheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _scanWifiNetworks() async {
    setState(() {
      _wifiBusy = true;
      _wifiMessage = 'Ricerca reti in corso…';
    });
    try {
      final networks = await const DeviceApi('http://192.168.4.1').scanWifi();
      if (!mounted) return;
      setState(() {
        _wifiNetworks = networks;
        _wifiMessage = networks.isEmpty
            ? 'Nessuna rete trovata. Puoi comunque inserire il nome manualmente.'
            : '${networks.length} reti trovate. Scegline una oppure inseriscila manualmente.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _wifiMessage =
            'Non riesco a contattare la cupola. Verifica di essere collegato a “LightDome-Setup”.';
      });
    } finally {
      if (mounted) setState(() => _wifiBusy = false);
    }
  }

  Future<void> _configureWifi() async {
    final ssid = _wifiSsidCtrl.text.trim();
    final password = _wifiPasswordCtrl.text;
    if (ssid.isEmpty) {
      setState(
        () => _wifiMessage = 'Inserisci o scegli il nome della rete Wi-Fi.',
      );
      return;
    }
    if (password.isNotEmpty && password.length < 8) {
      setState(
        () => _wifiMessage = 'La password deve avere almeno 8 caratteri.',
      );
      return;
    }
    setState(() {
      _wifiBusy = true;
      _wifiMessage = 'Salvataggio della configurazione…';
    });
    try {
      await const DeviceApi(
        'http://192.168.4.1',
      ).configureWifi(ssid: ssid, password: password);
      _wifiPasswordCtrl.clear();
      if (!mounted) return;
      setState(() {
        _wifiMessage =
            'Configurazione salvata. La cupola si riavvia: ricollegati alla rete di casa e usa lightdome.local.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _wifiMessage =
            'Configurazione non riuscita. Resta collegato a “LightDome-Setup” e riprova.';
      });
    } finally {
      if (mounted) setState(() => _wifiBusy = false);
    }
  }

  Widget _savedDevicesCard(
    BuildContext context,
    List<DeviceEntry> saved,
    DeviceController ctrl,
    DeviceDirectory directory,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dispositivi salvati',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final entry in saved)
              ListTile(
                leading: const Icon(Icons.devices_other),
                title: Text(entry.label),
                subtitle: Text(entry.baseUrl),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Rinomina',
                      onPressed: () => _renameEntry(entry, directory),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Rimuovi',
                      onPressed: () => directory.remove(entry.baseUrl),
                    ),
                  ],
                ),
                onTap: () {
                  _ipCtrl.text = entry.baseUrl;
                  ctrl.setIp(entry.baseUrl);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _discoverCard(
    BuildContext context,
    DeviceDirectory directory,
    List<DeviceEntry> discovered,
    DeviceController ctrl,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dispositivi in LAN',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (directory.discovering) const LinearProgressIndicator(),
            if (directory.discovering) const SizedBox(height: 8),
            if (discovered.isEmpty && !directory.discovering)
              const Text(
                'Nessun dispositivo trovato. Assicurati che cupola e telefono siano sulla stessa rete.',
              ),
            for (final entry in discovered)
              ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(entry.label),
                subtitle: Text(entry.baseUrl),
                trailing: IconButton(
                  icon: const Icon(Icons.bookmark_add_outlined),
                  tooltip: 'Salva',
                  onPressed: () =>
                      directory.addOrUpdate(entry.baseUrl, label: entry.label),
                ),
                onTap: () {
                  _ipCtrl.text = entry.baseUrl;
                  ctrl.setIp(entry.baseUrl);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _preferencesCard(AppSettings app) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Preferenze',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Aspetto', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<AppThemePreference>(
              segments: const [
                ButtonSegment(
                  value: AppThemePreference.system,
                  icon: Icon(Icons.brightness_auto_rounded),
                  label: Text('Sistema'),
                ),
                ButtonSegment(
                  value: AppThemePreference.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Chiaro'),
                ),
                ButtonSegment(
                  value: AppThemePreference.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Scuro'),
                ),
              ],
              selected: {app.themePreference},
              onSelectionChanged: (selection) {
                app.setThemePreference(selection.first);
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mostra anteprima cupola'),
              value: app.showPreview,
              onChanged: (v) => app.setShowPreview(v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mostra descrizioni controlli'),
              value: app.showDescriptions,
              onChanged: (v) => app.setShowDescriptions(v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _notesCard() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Note',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'La cupola funziona nella rete locale, senza cloud. Se risulta offline, controlla Wi-Fi, indirizzo e alimentazione. '
              'Telefono e cupola devono essere sulla stessa rete. Il controllo attuale usa HTTP.',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runDiscovery() async {
    await DeviceDirectory.I.discover();
  }

  Future<void> _renameEntry(
    DeviceEntry entry,
    DeviceDirectory directory,
  ) async {
    final ctrl = TextEditingController(text: entry.label);
    final newLabel = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rinomina dispositivo'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Nome'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newLabel != null && newLabel.isNotEmpty) {
      await directory.addOrUpdate(entry.baseUrl, label: newLabel);
    }
  }
}
