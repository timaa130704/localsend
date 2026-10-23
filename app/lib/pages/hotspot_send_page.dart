import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:linkisend_app/provider/device_info_provider.dart';
import 'package:linkisend_app/provider/http_provider.dart';
import 'package:linkisend_app/provider/network/send_provider.dart';
import 'package:linkisend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:linkisend_app/provider/settings_provider.dart';
import 'package:linkisend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:linkisend_app/util/native/file_picker.dart';
import 'package:linkisend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class HotspotSendPage extends StatefulWidget {
  const HotspotSendPage();

  @override
  State<HotspotSendPage> createState() => _HotspotSendPageState();
}

class _HotspotSendPageState extends State<HotspotSendPage> with Refena {
  final _pickerOptions = FilePickerOption.getOptionsForPlatform();
  bool _working = false;
  bool _handled = false;
  bool _connectionPending = false;
  bool _sessionOwnsConnection = false;
  String? _error;

  Future<void> _handleCode(String raw) async {
    if (_working || _handled) return;
    try {
      final invite = jsonDecode(raw) as Map<String, dynamic>;
      if (invite['type'] != 'linkisend-hotspot-v1') return;
      await _connectAndSend(
        ssid: invite['ssid'] as String,
        password: invite['password'] as String,
        ip: invite['ip'] as String?,
        port: invite['port'] as int,
        https: invite['https'] as bool,
      );
    } catch (e) {
      if (mounted && !_working) setState(() => _error = e.toString().split('\n').first);
    }
  }

  Future<void> _chooseWifiNetwork() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final networks = await android_channel.getNearbyHotspotsAndroid();
      if (!mounted) return;
      if (networks.isEmpty) {
        final manual = await _askNetworkDetails();
        if (!mounted) return;
        if (manual == null) {
          setState(() => _working = false);
          return;
        }
        final settings = ref.read(settingsProvider);
        await _connectAndSend(
          ssid: manual.$1,
          password: manual.$2,
          ip: null,
          port: settings.port,
          https: settings.https,
        );
        return;
      }
      final ssid = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Выбери точку доступа LinkiSend')),
              ...networks.map((name) => ListTile(
                    leading: const Icon(Icons.wifi),
                    title: Text(name),
                    onTap: () => context.pop(name),
                  )),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (ssid == null) {
        setState(() => _working = false);
        return;
      }
      final password = await _askPassword(ssid);
      if (!mounted) return;
      if (password == null || password.isEmpty) {
        setState(() => _working = false);
        return;
      }
      final settings = ref.read(settingsProvider);
      await _connectAndSend(ssid: ssid, password: password, ip: null, port: settings.port, https: settings.https);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = e.toString().split('\n').first;
      });
    }
  }

  Future<(String, String)?> _askNetworkDetails() async {
    final ssidController = TextEditingController();
    final passwordController = TextEditingController();
    final details = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Точка получателя не найдена'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Введи имя Wi‑Fi и пароль с экрана получателя.'),
            TextField(
              controller: ssidController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Имя сети, например AndroidShare_1234'),
            ),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Пароль'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => context.pop(), child: const Text('Отмена')),
          TextButton(
            onPressed: () => context.pop((ssidController.text.trim(), passwordController.text)),
            child: const Text('Подключить'),
          ),
        ],
      ),
    );
    ssidController.dispose();
    passwordController.dispose();
    if (details == null || details.$1.isEmpty || details.$2.isEmpty) return null;
    return details;
  }

  Future<String?> _askPassword(String ssid) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Пароль сети $ssid'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Пароль на экране получателя'),
        ),
        actions: [
          TextButton(onPressed: () => context.pop(), child: const Text('Отмена')),
          TextButton(onPressed: () => context.pop(controller.text), child: const Text('Подключить')),
        ],
      ),
    );
    controller.dispose();
    return password;
  }

  Future<void> _connectAndSend({
    required String ssid,
    required String password,
    required String? ip,
    required int port,
    required bool https,
  }) async {
    if (!_working) {
      setState(() {
        _working = true;
        _handled = true;
        _error = null;
      });
    } else {
      _handled = true;
    }
    try {
      final network = await android_channel.connectToHotspotAndroid(ssid: ssid, password: password);
      _connectionPending = true;
      if (!mounted) return;
      final granted = await android_channel.requestLocalNetworkPermissionAndroid();
      if (!granted) throw Exception('Разреши доступ к локальной сети для LinkiSend.');

      // Always prefer the gateway of the Wi-Fi network we just joined. The
      // address embedded in the QR may be the sender's cellular interface IP.
      final gatewayIp = network['ip'];
      final receiverIp = gatewayIp != null && gatewayIp.isNotEmpty ? gatewayIp : null;
      if (receiverIp == null || receiverIp.isEmpty) {
        throw Exception('Подключились к Wi‑Fi, но Android не сообщил адрес получателя.');
      }
      final payload = ref.read(deviceFullInfoProvider).toRegisterDto();
      final response = await ref.read(httpProvider).discovery.register(
            protocol: https ? ProtocolType.https : ProtocolType.http,
            ip: receiverIp,
            port: port,
            payload: payload,
          );
      final receiver = response.body.toDevice(receiverIp, port, https);

      ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
      if (!mounted) return;
      await AddFileDialog.open(context: context, options: _pickerOptions);
      if (!mounted) return;
      final files = ref.read(selectedSendingFilesProvider);
      if (files.isEmpty) {
        await android_channel.disconnectFromHotspotAndroid();
        _connectionPending = false;
        setState(() {
          _working = false;
          _handled = false;
        });
        return;
      }
      // startSession includes the upload itself, so the hotspot network must
      // remain bound even though this scanner page is popped before it starts.
      _sessionOwnsConnection = true;
      context.pop();
      try {
        await ref.notifier(sendProvider).startSession(target: receiver, files: files, background: false);
      } finally {
        await android_channel.disconnectFromHotspotAndroid();
        _connectionPending = false;
        _sessionOwnsConnection = false;
      }
    } catch (e) {
      if (_connectionPending) {
        await android_channel.disconnectFromHotspotAndroid();
        _connectionPending = false;
        _sessionOwnsConnection = false;
      }
      if (!mounted) return;
      setState(() {
        _working = false;
        _handled = false;
        _error = e.toString().split('\n').first;
      });
    }
  }

  @override
  void dispose() {
    if (_connectionPending && !_sessionOwnsConnection) {
      unawaited(android_channel.disconnectFromHotspotAndroid());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Подключить получателя')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                final value = capture.barcodes.firstOrNull?.rawValue;
                if (value != null) _handleCode(value); // ignore: discarded_futures
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(_working ? 'Подключаемся к точке доступа…' : 'Отсканируй QR получателя или выбери его Wi‑Fi точку'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _working ? null : _chooseWifiNetwork,
                  icon: const Icon(Icons.wifi_find),
                  label: const Text('Выбрать из списка Wi‑Fi'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
