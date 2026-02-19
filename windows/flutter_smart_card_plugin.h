#ifndef FLUTTER_PLUGIN_FLUTTER_SMART_CARD_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_SMART_CARD_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include <winscard.h>

namespace flutter_smart_card {

class FlutterSmartCardPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterSmartCardPlugin();

  virtual ~FlutterSmartCardPlugin();

  // Disallow copy and assign.
  FlutterSmartCardPlugin(const FlutterSmartCardPlugin&) = delete;
  FlutterSmartCardPlugin& operator=(const FlutterSmartCardPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  void ListReaders(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Connect(const std::string& reader, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Transmit(const std::vector<uint8_t>& apdu, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Disconnect(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  SCARDCONTEXT hContext_ = 0;
  SCARDHANDLE hCard_ = 0;
  DWORD dwProtocol_ = 0;
};

}  // namespace flutter_smart_card

#endif  // FLUTTER_PLUGIN_FLUTTER_SMART_CARD_PLUGIN_H_
