# flutter_smart_card

A Flutter plugin for communicating with smart card readers via USB. Supports Android, macOS, and Windows with platform-specific native implementations.

## Features

- **List readers** - Discover connected smart card readers
- **Connect/Disconnect** - Establish and close sessions with smart cards
- **Transmit APDU** - Send and receive raw APDU commands
- **Tachograph DDD extraction** - Read and export DDD files from EU tachograph driver cards (G1 and G2)

## Platform Support

| Platform | Implementation | Notes |
|----------|---------------|-------|
| Android  | USB Host (CCID) | Direct USB communication, requires USB host support |
| macOS    | CryptoTokenKit | Uses system smart card framework |
| Windows  | WinSCard | Uses Windows Smart Card API |

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_smart_card: ^0.2.0
```

## Platform Setup

### Android

Add USB host feature to your `AndroidManifest.xml`:

```xml
<uses-feature android:name="android.hardware.usb.host" android:required="true" />
```

The plugin handles USB permission requests automatically.

Minimum SDK: 26 (Android 8.0)

### macOS

Add the following entitlement to your `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.smartcard</key>
<true/>
```

### Windows

No additional setup required. The plugin uses the WinSCard API which is available on all Windows versions.

## Usage

### Basic Smart Card Communication

```dart
import 'package:flutter_smart_card/flutter_smart_card.dart';

final smartCard = FlutterSmartCard();

// List available readers
final readers = await smartCard.listReaders();

// Connect to the first reader
if (readers.isNotEmpty) {
  await smartCard.connect(readers.first);

  // Send an APDU command (e.g. SELECT PSE)
  final pse = '1PAY.SYS.DDF01'.codeUnits;
  final response = await smartCard.transmit(
    Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, pse.length, ...pse, 0x00]),
  );

  // Disconnect
  await smartCard.disconnect();
}
```

## Tachograph Driver Card (DDD) Extraction

The example app includes `TachographCardReader`, a helper class that reads EU tachograph driver cards and produces a standards-compliant DDD byte buffer.

### What it does

- Reads MF-level EFs (`EF_ICC`, `EF_IC`, `EF_DIR`, etc.)
- Reads the G1 DF (AID `TACHO`) including all activity, events, faults, and identification files
- Reads the G2 DF (AID `SMRDT`) with extended G2 EFs including GNSS places and vehicle units
- Captures RSA (G1) and ECDSA (G2) signatures for each signed EF
- Assembles the data into a DDD-format byte buffer (tag + type + length + data blocks)
- Parses `EF_Identification` to extract driver info: name, birth date, card number, country code, and issuing authority

### Example usage

```dart
import 'package:flutter_smart_card/flutter_smart_card.dart';
import 'tachograph_card_reader.dart';

final smartCard = FlutterSmartCard();
await smartCard.connect(readerName);

final reader = TachographCardReader(
  (apdu) => smartCard.transmit(Uint8List.fromList(apdu)),
  onProgress: (efName, current, total) {
    print('Reading $efName ($current/$total)');
  },
);

final (dddBytes, driverInfo) = await reader.read();

print('Driver: ${driverInfo.displayName}');
print('Card number: ${driverInfo.cardNumber}');
// Save dddBytes to a .ddd file

await smartCard.disconnect();
```

## API Reference

### FlutterSmartCard

| Method | Description |
|--------|-------------|
| `listReaders()` | Returns a list of connected smart card reader names |
| `connect(String reader)` | Connects to the specified reader, returns `true` on success |
| `transmit(Uint8List apdu)` | Sends an APDU command and returns the response |
| `disconnect()` | Disconnects from the current reader |

## License

BSD 3-Clause License. See [LICENSE](LICENSE) for details.
