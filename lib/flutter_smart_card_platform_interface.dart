import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:typed_data';

import 'flutter_smart_card_method_channel.dart';

abstract class FlutterSmartCardPlatform extends PlatformInterface {
  FlutterSmartCardPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterSmartCardPlatform _instance = MethodChannelFlutterSmartCard();

  static FlutterSmartCardPlatform get instance => _instance;

  static set instance(FlutterSmartCardPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<List<String>> listReaders() {
    throw UnimplementedError('listReaders() has not been implemented.');
  }

  Future<bool> connect(String reader) {
    throw UnimplementedError('connect() has not been implemented.');
  }

  Future<Uint8List> transmit(Uint8List apdu) {
    throw UnimplementedError('transmit() has not been implemented.');
  }

  Future<void> disconnect() {
    throw UnimplementedError('disconnect() has not been implemented.');
  }
}
