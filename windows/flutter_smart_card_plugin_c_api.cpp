#include "include/flutter_smart_card/flutter_smart_card_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_smart_card_plugin.h"

void FlutterSmartCardPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_smart_card::FlutterSmartCardPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
