import 'dart:typed_data';

import 'flutter_smart_card_platform_interface.dart';

class FlutterSmartCard {
  Future<List<String>> listReaders() {
    return FlutterSmartCardPlatform.instance.listReaders();
  }

  Future<bool> connect(String reader) {
    return FlutterSmartCardPlatform.instance.connect(reader);
  }

  Future<Uint8List> transmit(Uint8List apdu) {
    return FlutterSmartCardPlatform.instance.transmit(apdu);
  }

  Future<void> disconnect() {
    return FlutterSmartCardPlatform.instance.disconnect();
  }
}
