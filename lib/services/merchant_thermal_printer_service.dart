import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

import 'merchant_bluetooth_printer_service.dart';
import 'merchant_escpos_encoder.dart';
import 'merchant_receipt_raster.dart';

class MerchantThermalPrinterService {
  MerchantThermalPrinterService._();

  static final MerchantThermalPrinterService instance =
      MerchantThermalPrinterService._();

  static const String _wifiHostKey = 'merchant_wifi_printer_host';
  static const String _wifiPortKey = 'merchant_wifi_printer_port';
  static const String _savedPrinterKey = 'merchant_saved_thermal_printer';

  final ThermalPrinterFlutter _plugin = ThermalPrinterFlutter();
  static const MethodChannel _thermalChannel = MethodChannel(
    'thermal_printer_flutter',
  );
  Printer? _activeBlePrinter;

  Future<void> printViaWifi(BuildContext context, Uint8List receiptPng) async {
    final printer = await _resolveNetworkPrinter(context);
    await _printEscPos(receiptPng, printer);
    await _rememberPrinter(printer);
    _showSuccess(context, 'พิมพ์ผ่าน Wi-Fi แล้ว');
  }

  Future<void> printViaBle(
    BuildContext context,
    Uint8List receiptPng,
  ) async {
    await _ensureBleReady();
    final printer = await _resolveBlePrinter(context);
    await _printBleEscPos(receiptPng, printer);
    await _rememberPrinter(printer);
    _showSuccess(context, 'พิมพ์ผ่าน Bluetooth แล้ว');
  }

  /// True when we can print without a 5s BLE scan (saved or live session).
  Future<bool> hasBlePrinterReady() async {
    if (_activeBlePrinter != null &&
        _activeBlePrinter!.bleAddress.trim().isNotEmpty) {
      if (await _plugin.isConnected(printer: _activeBlePrinter!)) {
        return true;
      }
    }
    final saved = await _loadSavedPrinter();
    return saved != null &&
        saved.type == PrinterType.bluetooth &&
        saved.bleAddress.trim().isNotEmpty;
  }

  Future<void> printViaUsb(BuildContext context, Uint8List receiptPng) async {
    if (!Platform.isAndroid) {
      throw const PrinterUserException('USB รองรับเฉพาะ Android');
    }

    final printer = await _resolveUsbPrinter(context);
    await _printEscPos(receiptPng, printer);
    await _rememberPrinter(printer);
    _showSuccess(context, 'พิมพ์ผ่าน USB แล้ว');
  }

  Future<void> _printEscPos(Uint8List receiptPng, Printer printer) async {
    final bytes = await buildEscPosReceiptBytes(receiptPng);
    final connected = await _plugin.connect(printer: printer);
    if (!connected) {
      throw const PrinterUserException('เชื่อมต่อเครื่องพิมพ์ไม่สำเร็จ');
    }
    try {
      await _plugin.printBytes(bytes: bytes, printer: printer);
    } finally {
      await _plugin.disconnect(printer: printer);
    }
  }

  Future<void> _printBleEscPos(
    Uint8List receiptPng,
    Printer printer,
  ) async {
    late final Uint8List escPosBytes;
    try {
      if (Platform.isIOS) {
        // S1PRO uses Lujiang/LuckPrinter commands and a native 384-dot raster.
        escPosBytes = buildS1ProReceiptBytes(receiptPng);
      } else {
        escPosBytes = Uint8List.fromList(
          await buildEscPosReceiptBytes(receiptPng, pocketPrinter: true),
        );
      }
    } catch (error, stack) {
      debugPrint('Printer BLE encode error: $error\n$stack');
      if (Platform.isIOS) {
        throw PrinterUserException(
          'สร้างข้อมูลพิมพ์ไม่สำเร็จ — ลองพิมพ์อีกครั้ง',
        );
      }
      try {
        escPosBytes = Uint8List.fromList(
          await buildEscPosReceiptBytes(receiptPng, pocketPrinter: true),
        );
      } catch (retryError, retryStack) {
        debugPrint('Printer BLE encode retry error: $retryError\n$retryStack');
        throw PrinterUserException(
          'สร้างข้อมูลพิมพ์ไม่สำเร็จ — ลองพิมพ์อีกครั้ง',
        );
      }
    }
    final bytes = escPosBytes;
    debugPrint(
      'Printer BLE ${printer.name} ${printer.bleAddress} bytes=${bytes.length}',
    );
    await _ensureBleConnected(printer);

    try {
      for (var attempt = 0; attempt < 8; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        debugPrint('Printer BLE write attempt ${attempt + 1}');
        final printed = await _thermalChannel.invokeMethod<bool>(
          'writebytes',
          bytes,
        );
        debugPrint('Printer BLE write result=$printed');
        if (printed == true) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
          return;
        }
      }
      _activeBlePrinter = null;
      throw const PrinterUserException(
        'เชื่อมต่อแล้วแต่เครื่องพิมพ์ยังไม่พร้อมรับข้อมูล กรุณาลองใหม่',
      );
    } on PlatformException catch (error) {
      debugPrint('Printer BLE write error: ${error.code} ${error.message}');
      _activeBlePrinter = null;
      throw PrinterUserException(
        'ส่งงานพิมพ์ผ่าน Bluetooth ไม่สำเร็จ: ${error.message ?? error.code}',
      );
    }
  }

  Future<void> _ensureBleConnected(Printer printer) async {
    final samePrinter =
        _activeBlePrinter?.bleAddress == printer.bleAddress &&
        printer.bleAddress.trim().isNotEmpty;
    if (samePrinter) {
      final stillConnected = await _plugin.isConnected(printer: printer);
      if (stillConnected) {
        debugPrint('Printer BLE already connected ${printer.bleAddress}');
        return;
      }
    }

    debugPrint('Printer BLE connect ${printer.name} ${printer.bleAddress}');
    final connected = await _plugin.connect(printer: printer);
    debugPrint('Printer BLE connect result=$connected');
    if (!connected) {
      _activeBlePrinter = null;
      throw const PrinterUserException(
        'เชื่อมต่อเครื่องพิมพ์ไม่สำเร็จ — รอช่องส่งข้อมูลไม่ทันหรือเครื่องหลุด',
      );
    }
    _activeBlePrinter = printer;
    // Mini Pocket S1 starts the motor as soon as GATT is up; wait before raster.
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  Future<void> _ensureBleReady() async {
    var granted = await _plugin.checkBluetoothPermissions();
    if (Platform.isIOS && !granted) {
      // CBCentralManager initially reports "unknown" while iOS initializes
      // Bluetooth. Give it a moment before treating that as a denial.
      for (var attempt = 0; attempt < 4 && !granted; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        granted = await _plugin.checkBluetoothPermissions();
      }
    }
    if (!granted) {
      throw const PrinterUserException(
        'กรุณาอนุญาต Bluetooth เพื่อเชื่อมต่อเครื่องพิมพ์',
      );
    }
    final enabled = await _plugin.isBluetoothEnabled();
    if (!enabled) {
      if (Platform.isIOS) {
        throw const PrinterUserException(
          'กรุณาเปิด Bluetooth ในการตั้งค่า iPhone ก่อนพิมพ์',
        );
      }
      final turnedOn = await _plugin.enableBluetooth();
      if (!turnedOn) {
        throw const PrinterUserException('กรุณาเปิด Bluetooth ก่อนพิมพ์');
      }
    }
  }

  Future<Printer> _resolveNetworkPrinter(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    var savedHost = prefs.getString(_wifiHostKey)?.trim() ?? '';
    final savedPort = prefs.getString(_wifiPortKey)?.trim().isNotEmpty == true
        ? prefs.getString(_wifiPortKey)!.trim()
        : '9100';

    final savedThermal = await _loadSavedPrinter();
    if (savedThermal != null &&
        savedThermal.type == PrinterType.network &&
        savedThermal.ip.trim().isNotEmpty) {
      savedHost = savedThermal.ip.trim();
    }

    if (!context.mounted) {
      throw const PrinterUserException('ไม่สามารถตั้งค่าเครื่องพิมพ์ได้');
    }

    final result = await showDialog<_WifiPrinterResult>(
      context: context,
      builder: (dialogContext) => _WifiPrinterDialog(
        initialHost: savedHost,
        initialPort: savedPort,
        onDiscover: _discoverNetworkPrinters,
      ),
    );

    if (result == null) {
      throw const PrinterUserException('ยกเลิกการตั้งค่าเครื่องพิมพ์ Wi-Fi');
    }

    await prefs.setString(_wifiHostKey, result.host);
    await prefs.setString(_wifiPortKey, result.port);

    return Printer(
      type: PrinterType.network,
      name: result.name ?? 'Wi-Fi Printer',
      ip: result.host,
      port: result.port,
    );
  }

  Future<List<Printer>> _discoverNetworkPrinters(
    void Function(String message) onProgress,
  ) async {
    return _plugin.discoverNetworkPrinters(
      requireConfirmation: true,
      onProgress: onProgress,
    );
  }

  Future<Printer> _resolveBlePrinter(BuildContext context) async {
    if (_activeBlePrinter != null &&
        _activeBlePrinter!.bleAddress.trim().isNotEmpty) {
      if (await _plugin.isConnected(printer: _activeBlePrinter!)) {
        return _activeBlePrinter!;
      }
    }

    final saved = await _loadSavedPrinter();
    if (saved != null &&
        saved.type == PrinterType.bluetooth &&
        saved.bleAddress.trim().isNotEmpty) {
      return saved;
    }

    final devices = await _plugin.getPrinters(
      printerType: PrinterType.bluetooth,
    );
    if (devices.isEmpty) {
      throw const PrinterUserException(
        'ไม่พบเครื่องพิมพ์ Bluetooth — เปิดเครื่องพิมพ์แล้วลองใหม่ (iOS รองรับ BLE)',
      );
    }

    if (!context.mounted) {
      throw const PrinterUserException('ไม่สามารถเลือกเครื่องพิมพ์ได้');
    }

    final selected = await showDialog<Printer>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('เลือกเครื่องพิมพ์ Bluetooth'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: devices.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final device = devices[index];
                final label = device.name.trim().isNotEmpty
                    ? device.name
                    : device.bleAddress;
                return ListTile(
                  title: Text(label),
                  subtitle: device.bleAddress.trim().isNotEmpty
                      ? Text(device.bleAddress)
                      : null,
                  onTap: () => Navigator.of(dialogContext).pop(device),
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('ยกเลิก'),
            ),
          ],
        );
      },
    );

    if (selected == null) {
      throw const PrinterUserException('ยกเลิกการเลือกเครื่องพิมพ์');
    }
    return selected;
  }

  Future<Printer> _resolveUsbPrinter(BuildContext context) async {
    final saved = await _loadSavedPrinter();
    final devices = await _plugin.getPrinters(printerType: PrinterType.usb);
    if (devices.isEmpty) {
      throw const PrinterUserException(
        'ไม่พบเครื่องพิมพ์ USB — เชื่อมสาย OTG แล้วลองใหม่',
      );
    }

    devices.sort((a, b) {
      final aSaved =
          saved?.type == PrinterType.usb &&
          saved?.usbAddress == a.usbAddress;
      final bSaved =
          saved?.type == PrinterType.usb &&
          saved?.usbAddress == b.usbAddress;
      if (aSaved == bSaved) return 0;
      return aSaved ? -1 : 1;
    });

    if (!context.mounted) {
      throw const PrinterUserException('ไม่สามารถเลือกเครื่องพิมพ์ได้');
    }

    final selected = await showDialog<Printer>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('เลือกเครื่องพิมพ์ USB'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: devices.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final device = devices[index];
                return ListTile(
                  title: Text(
                    device.name.trim().isNotEmpty
                        ? device.name
                        : device.usbAddress,
                  ),
                  trailing:
                      saved?.type == PrinterType.usb &&
                          saved?.usbAddress == device.usbAddress
                      ? const Chip(label: Text('ล่าสุด'))
                      : null,
                  onTap: () => Navigator.of(dialogContext).pop(device),
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('ยกเลิก'),
            ),
          ],
        );
      },
    );

    if (selected == null) {
      throw const PrinterUserException('ยกเลิกการเลือกเครื่องพิมพ์');
    }
    return selected;
  }

  Future<Printer?> _loadSavedPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_savedPrinterKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      return Printer.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberPrinter(Printer printer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_savedPrinterKey, printer.toJson());
  }

  void _showSuccess(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _WifiPrinterResult {
  const _WifiPrinterResult({
    required this.host,
    required this.port,
    this.name,
  });

  final String host;
  final String port;
  final String? name;
}

class _WifiPrinterDialog extends StatefulWidget {
  const _WifiPrinterDialog({
    required this.initialHost,
    required this.initialPort,
    required this.onDiscover,
  });

  final String initialHost;
  final String initialPort;
  final Future<List<Printer>> Function(void Function(String message) onProgress)
  onDiscover;

  @override
  State<_WifiPrinterDialog> createState() => _WifiPrinterDialogState();
}

class _WifiPrinterDialogState extends State<_WifiPrinterDialog> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  bool _discovering = false;
  String? _progress;
  List<Printer> _discovered = <Printer>[];

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.initialHost);
    _portController = TextEditingController(text: widget.initialPort);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _discovering = true;
      _progress = 'กำลังค้นหาเครื่องพิมพ์ในเครือข่าย...';
      _discovered = <Printer>[];
    });
    try {
      final found = await widget.onDiscover((message) {
        if (!mounted) return;
        setState(() => _progress = message);
      });
      if (!mounted) return;
      setState(() {
        _discovered = found;
        _progress = found.isEmpty
            ? 'ไม่พบเครื่องพิมพ์ — กรอก IP เอง'
            : 'พบ ${found.length} เครื่อง';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _progress = 'ค้นหาไม่สำเร็จ: $error');
    } finally {
      if (mounted) {
        setState(() => _discovering = false);
      }
    }
  }

  void _submit({String? name}) {
    final host = _hostController.text.trim();
    final port = _portController.text.trim().isEmpty
        ? '9100'
        : _portController.text.trim();
    if (host.isEmpty) {
      setState(() => _progress = 'กรุณากรอก IP เครื่องพิมพ์');
      return;
    }
    Navigator.of(context).pop(
      _WifiPrinterResult(host: host, port: port, name: name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('เครื่องพิมพ์ Wi-Fi'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'IP เครื่องพิมพ์',
                  hintText: '192.168.1.100',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  hintText: '9100',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _discovering ? null : _scan,
                icon: _discovering
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search_rounded),
                label: const Text('ค้นหาในเครือข่าย'),
              ),
              if (_progress != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _progress!,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                ),
              ],
              if (_discovered.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                ..._discovered.map((printer) {
                  final label = printer.name.trim().isNotEmpty
                      ? printer.name
                      : printer.ip;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label),
                    subtitle: Text('${printer.ip}:${printer.port}'),
                    onTap: () {
                      _hostController.text = printer.ip;
                      _portController.text = printer.port;
                      _submit(name: label);
                    },
                  );
                }),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('ยกเลิก'),
        ),
        FilledButton(
          onPressed: () => _submit(),
          child: const Text('ใช้ IP นี้'),
        ),
      ],
    );
  }
}
