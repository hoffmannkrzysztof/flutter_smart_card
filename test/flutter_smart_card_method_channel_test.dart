import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_card/flutter_smart_card_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelFlutterSmartCard platform = MethodChannelFlutterSmartCard();
  const MethodChannel channel = MethodChannel('flutter_smart_card');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        switch (methodCall.method) {
          case 'listReaders':
            return <String>['Reader 1'];
          case 'connect':
            return true;
          case 'transmit':
            return Uint8List.fromList([0x90, 0x00]);
          case 'disconnect':
            return null;
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('listReaders', () async {
    final readers = await platform.listReaders();
    expect(readers, ['Reader 1']);
  });

  test('connect', () async {
    final result = await platform.connect('Reader 1');
    expect(result, true);
  });

  test('transmit', () async {
    final result = await platform.transmit(Uint8List.fromList([0x00, 0xA4]));
    expect(result, isA<Uint8List>());
  });

  test('disconnect', () async {
    await platform.disconnect();
  });
}
