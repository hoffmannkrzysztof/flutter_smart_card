import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_card/flutter_smart_card_platform_interface.dart';
import 'package:flutter_smart_card/flutter_smart_card_method_channel.dart';

void main() {
  test('$MethodChannelFlutterSmartCard is the default instance', () {
    expect(
      FlutterSmartCardPlatform.instance,
      isInstanceOf<MethodChannelFlutterSmartCard>(),
    );
  });
}
