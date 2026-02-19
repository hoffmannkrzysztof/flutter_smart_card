#include "flutter_smart_card_plugin.h"

#include <windows.h>
#include <vector>

namespace {
std::wstring Utf8ToWide(const std::string &str) {
  if (str.empty()) return std::wstring();
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), NULL, 0);
  std::wstring wstrTo(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, &str[0], (int)str.size(), &wstrTo[0], size_needed);
  return wstrTo;
}

std::string WideToUtf8(const std::wstring &wstr) {
  if (wstr.empty()) return std::string();
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), NULL, 0, NULL, NULL);
  std::string strTo(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), &strTo[0], size_needed, NULL, NULL);
  return strTo;
}
}  // namespace

namespace flutter_smart_card {

void FlutterSmartCardPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_smart_card",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterSmartCardPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

FlutterSmartCardPlugin::FlutterSmartCardPlugin() {}

FlutterSmartCardPlugin::~FlutterSmartCardPlugin() {
  if (hCard_) {
    SCardDisconnect(hCard_, SCARD_LEAVE_CARD);
  }
  if (hContext_) {
    SCardReleaseContext(hContext_);
  }
}

void FlutterSmartCardPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "listReaders") {
    ListReaders(std::move(result));
  } else if (method_call.method_name() == "connect") {
    const auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    std::string reader;
    if (arguments) {
      auto it = arguments->find(flutter::EncodableValue("reader"));
      if (it != arguments->end() && std::holds_alternative<std::string>(it->second)) {
        reader = std::get<std::string>(it->second);
      }
    }
    if (reader.empty()) {
      result->Error("INVALID_ARGUMENT", "Reader name is required");
      return;
    }
    Connect(reader, std::move(result));
  } else if (method_call.method_name() == "transmit") {
    const auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    std::vector<uint8_t> apdu;
    if (arguments) {
      auto it = arguments->find(flutter::EncodableValue("apdu"));
      if (it != arguments->end() && std::holds_alternative<std::vector<uint8_t>>(it->second)) {
        apdu = std::get<std::vector<uint8_t>>(it->second);
      }
    }
    if (apdu.empty()) {
      result->Error("INVALID_ARGUMENT", "APDU data is required");
      return;
    }
    Transmit(apdu, std::move(result));
  } else if (method_call.method_name() == "disconnect") {
    Disconnect(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void FlutterSmartCardPlugin::ListReaders(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!hContext_) {
    LONG lReturn = SCardEstablishContext(SCARD_SCOPE_USER, NULL, NULL, &hContext_);
    if (lReturn != SCARD_S_SUCCESS) {
      result->Error("CONTEXT_ERROR", "Failed to establish context");
      return;
    }
  }

  LPTSTR pmszReaders = NULL;
  DWORD cch = SCARD_AUTOALLOCATE;
  LONG lReturn = SCardListReaders(hContext_, NULL, (LPTSTR)&pmszReaders, &cch);

  if (lReturn != SCARD_S_SUCCESS || pmszReaders == NULL) {
    result->Success(flutter::EncodableList());
    return;
  }

  flutter::EncodableList readers_list;
  LPTSTR pReader = pmszReaders;
  while (*pReader != '\0') {
#ifdef UNICODE
    std::wstring wreader(pReader);
    readers_list.push_back(flutter::EncodableValue(WideToUtf8(wreader)));
#else
    readers_list.push_back(flutter::EncodableValue(std::string(pReader)));
#endif
    pReader += lstrlen(pReader) + 1;
  }
  SCardFreeMemory(hContext_, pmszReaders);

  result->Success(readers_list);
}

void FlutterSmartCardPlugin::Connect(
    const std::string &reader,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!hContext_) {
    result->Error("CONTEXT_ERROR", "Context not established");
    return;
  }

  std::wstring wreader = Utf8ToWide(reader);

  LONG lReturn = SCardConnect(
      hContext_, (LPCTSTR)wreader.c_str(), SCARD_SHARE_SHARED,
      SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, &hCard_, &dwProtocol_);

  if (lReturn != SCARD_S_SUCCESS) {
    result->Error("CONNECTION_FAILED", "Failed to connect",
                  flutter::EncodableValue((int64_t)lReturn));
    return;
  }

  result->Success(flutter::EncodableValue(true));
}

void FlutterSmartCardPlugin::Transmit(
    const std::vector<uint8_t> &apdu,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!hCard_) {
    result->Error("NOT_CONNECTED", "Card not connected");
    return;
  }

  const SCARD_IO_REQUEST *pioSendPci;
  switch (dwProtocol_) {
  case SCARD_PROTOCOL_T0:
    pioSendPci = SCARD_PCI_T0;
    break;
  case SCARD_PROTOCOL_T1:
    pioSendPci = SCARD_PCI_T1;
    break;
  default:
    pioSendPci = SCARD_PCI_T0;
    break;
  }

  BYTE pbRecvBuffer[2048];
  DWORD pcbRecvLength = sizeof(pbRecvBuffer);

  LONG lReturn = SCardTransmit(hCard_, pioSendPci, apdu.data(), (DWORD)apdu.size(),
                                NULL, pbRecvBuffer, &pcbRecvLength);

  if (lReturn != SCARD_S_SUCCESS) {
    result->Error("TRANSMIT_FAILED", "Failed to transmit",
                  flutter::EncodableValue((int64_t)lReturn));
    return;
  }

  std::vector<uint8_t> response(pbRecvBuffer, pbRecvBuffer + pcbRecvLength);
  result->Success(flutter::EncodableValue(response));
}

void FlutterSmartCardPlugin::Disconnect(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (hCard_) {
    SCardDisconnect(hCard_, SCARD_LEAVE_CARD);
    hCard_ = 0;
  }
  result->Success(flutter::EncodableValue());
}

}  // namespace flutter_smart_card
