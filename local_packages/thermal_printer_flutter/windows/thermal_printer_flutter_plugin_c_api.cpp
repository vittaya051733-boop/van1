#include "include/thermal_printer_flutter/thermal_printer_flutter_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "thermal_printer_flutter_plugin.h"

void ThermalPrinterFlutterPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  thermal_printer_flutter::ThermalPrinterFlutterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
