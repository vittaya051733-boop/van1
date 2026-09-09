import 'dart:io' show Platform;

import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MerchantBluetoothPrinterService {
  MerchantBluetoothPrinterService._();

  static final MerchantBluetoothPrinterService instance =
      MerchantBluetoothPrinterService._();

  static const String _savedAddressKey = 'merchant_bluetooth_printer_address';
  final BlueThermalPrinter _printer = BlueThermalPrinter.instance;

  Future<void> ensurePermissions() async {
    if (!Platform.isAndroid) {
      return;
    }

    final permissions = <Permission>[
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
    ];

    for (final permission in permissions) {
      final status = await permission.status;
      if (status.isGranted || status.isLimited) {
        continue;
      }
      final result = await permission.request();
      if (!result.isGranted && !result.isLimited) {
        throw const PrinterUserException(
          'กรุณาอนุญาต Bluetooth และตำแหน่งเพื่อเชื่อมต่อเครื่องพิมพ์',
        );
      }
    }
  }

  Future<BluetoothDevice> resolvePrinterDevice(BuildContext context) async {
    await ensurePermissions();

    final isOn = await _printer.isOn;
    if (isOn != true) {
      throw const PrinterUserException(
        'กรุณาเปิด Bluetooth ก่อนพิมพ์',
      );
    }

    final devices = await _printer.getBondedDevices();
    if (devices.isEmpty) {
      throw const PrinterUserException(
        'ไม่พบเครื่องพิมพ์ที่จับคู่แล้ว — ไปที่ตั้งค่า Bluetooth ของเครื่องแล้วจับคู่เครื่องพิมพ์ก่อน',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    final savedAddress = prefs.getString(_savedAddressKey)?.trim();
    if (savedAddress != null && savedAddress.isNotEmpty) {
      final savedDevice = devices.cast<BluetoothDevice?>().firstWhere(
        (device) => device?.address == savedAddress,
        orElse: () => null,
      );
      if (savedDevice != null) {
        return savedDevice;
      }
    }

    if (devices.length == 1) {
      await _rememberDevice(devices.first);
      return devices.first;
    }

    if (!context.mounted) {
      throw const PrinterUserException('ไม่สามารถเลือกเครื่องพิมพ์ได้');
    }

    final selected = await showDialog<BluetoothDevice>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('เลือกเครื่องพิมพ์'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: devices.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final device = devices[index];
                final name = device.name?.trim();
                final label = name == null || name.isEmpty
                    ? device.address ?? 'ไม่ทราบชื่อ'
                    : '$name\n${device.address ?? ''}';
                return ListTile(
                  title: Text(label),
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

    await _rememberDevice(selected);
    return selected;
  }

  String? _connectedAddress;

  Future<void> connect(BluetoothDevice device) async {
    try {
      final connected = await _printer.isConnected;
      final address = device.address?.trim();
      if (connected == true &&
          address != null &&
          address.isNotEmpty &&
          _connectedAddress == address) {
        return;
      }
      if (connected == true) {
        try {
          await _printer.disconnect();
        } catch (_) {}
        _connectedAddress = null;
      }
      await _printer.connect(device);
      _connectedAddress = address;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    } on PlatformException catch (error) {
      _connectedAddress = null;
      throw PrinterUserException(_friendlyConnectError(error));
    }
  }

  Future<void> disconnectSilently() async {
    _connectedAddress = null;
    try {
      await _printer.disconnect();
    } catch (_) {}
  }

  BlueThermalPrinter get printer => _printer;

  Future<void> _rememberDevice(BluetoothDevice device) async {
    final address = device.address?.trim();
    if (address == null || address.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_savedAddressKey, address);
  }

  String _friendlyConnectError(PlatformException error) {
    final message = error.message?.toLowerCase() ?? '';
    if (message.contains('socket') ||
        message.contains('timeout') ||
        message.contains('read failed')) {
      return 'เชื่อมต่อเครื่องพิมพ์ไม่สำเร็จ — ตรวจว่าเครื่องพิมพ์เปิดอยู่ อยู่ใกล้ๆ และไม่ได้เชื่อมกับมือถือเครื่องอื่น';
    }
    if (message.contains('already connected')) {
      return 'เครื่องพิมพ์กำลังเชื่อมต่ออยู่แล้ว — ลองปิด-เปิดเครื่องพิมพ์แล้วพิมพ์ใหม่';
    }
    if (message.contains('device not found')) {
      return 'ไม่พบเครื่องพิมพ์ — ลองจับคู่ Bluetooth ใหม่';
    }
    if (error.code == 'no_permissions') {
      return 'กรุณาอนุญาต Bluetooth เพื่อเชื่อมต่อเครื่องพิมพ์';
    }
    return 'เชื่อมต่อเครื่องพิมพ์ไม่สำเร็จ';
  }
}

class PrinterUserException implements Exception {
  const PrinterUserException(this.message);

  final String message;

  @override
  String toString() => message;
}
