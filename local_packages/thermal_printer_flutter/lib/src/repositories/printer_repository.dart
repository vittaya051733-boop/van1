import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

abstract class PrinterRepository {
  Future<List<Printer>> getPrinters();
  Future<bool> connect(Printer printer);
  Future<void> disconnect(Printer printer);
  Future<void> printBytes({required List<int> bytes, required Printer printer});
  Future<bool> isConnected(Printer printer);
}
