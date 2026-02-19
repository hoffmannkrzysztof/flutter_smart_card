import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_smart_card_platform_interface.dart';

class MethodChannelFlutterSmartCard extends FlutterSmartCardPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_smart_card');

  @override
  Future<List<String>> listReaders() async {
    final List<dynamic> readers = await methodChannel.invokeMethod('listReaders');
    return readers.cast<String>();
  }

  @override
  Future<bool> connect(String reader) async {
    final bool result = await methodChannel.invokeMethod('connect', {
      'reader': reader,
    });
    return result;
  }

  @override
  Future<Uint8List> transmit(Uint8List apdu) async {
    final Uint8List response = await methodChannel.invokeMethod('transmit', {
      'apdu': apdu,
    });
    return response;
  }

  @override
  Future<void> disconnect() async {
    await methodChannel.invokeMethod('disconnect');
  }
}
