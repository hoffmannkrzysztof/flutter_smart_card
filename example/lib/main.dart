import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_smart_card/flutter_smart_card.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Card Reader Example',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const SmartCardPage(),
    );
  }
}

class SmartCardPage extends StatefulWidget {
  const SmartCardPage({super.key});

  @override
  State<SmartCardPage> createState() => _SmartCardPageState();
}

class _SmartCardPageState extends State<SmartCardPage> {
  final _smartCard = FlutterSmartCard();
  final _log = <String>[];

  List<String> _readers = [];
  String? _selectedReader;
  bool _isConnected = false;
  bool _isBusy = false;

  // Parsed card info
  String? _cardholderName;
  String? _cardNumber;
  String? _expiryDate;
  String? _applicationLabel;

  void _addLog(String message) {
    setState(() {
      _log.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $message');
    });
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  /// Transmit APDU and handle 61 XX (GET RESPONSE) automatically
  Future<Uint8List> _transmitApdu(List<int> apdu) async {
    _addLog('>> ${_hex(apdu)}');
    var response = await _smartCard.transmit(Uint8List.fromList(apdu));
    _addLog('<< ${_hex(response)}');

    // Handle 61 XX: more data available, need GET RESPONSE
    while (response.length >= 2 &&
        response[response.length - 2] == 0x61) {
      final le = response[response.length - 1];
      _addLog('>> GET RESPONSE (Le=$le)');
      final getResp = await _smartCard.transmit(
        Uint8List.fromList([0x00, 0xC0, 0x00, 0x00, le]),
      );
      _addLog('<< ${_hex(getResp)}');
      // Combine: previous data (without SW) + new response
      final combined = <int>[
        ...response.sublist(0, response.length - 2),
        ...getResp,
      ];
      response = Uint8List.fromList(combined);
    }

    // Handle 6C XX: wrong Le, retry with correct Le
    if (response.length >= 2 && response[response.length - 2] == 0x6C) {
      final correctLe = response[response.length - 1];
      final retryApdu = List<int>.from(apdu);
      if (retryApdu.isNotEmpty) {
        retryApdu[retryApdu.length - 1] = correctLe;
      }
      _addLog('>> Retry with Le=$correctLe');
      response = await _smartCard.transmit(Uint8List.fromList(retryApdu));
      _addLog('<< ${_hex(response)}');
    }

    return response;
  }

  /// Get SW1 and SW2 from response
  (int, int) _sw(Uint8List response) {
    if (response.length < 2) return (0, 0);
    return (response[response.length - 2], response[response.length - 1]);
  }

  /// Check if SW indicates success
  bool _isSuccess(Uint8List response) {
    final (sw1, sw2) = _sw(response);
    return sw1 == 0x90 && sw2 == 0x00;
  }

  /// Get data portion (without SW1 SW2)
  Uint8List _data(Uint8List response) {
    if (response.length < 2) return Uint8List(0);
    return response.sublist(0, response.length - 2);
  }

  Future<void> _listReaders() async {
    setState(() => _isBusy = true);
    try {
      final readers = await _smartCard.listReaders();
      setState(() {
        _readers = readers;
        _selectedReader = readers.isNotEmpty ? readers.first : null;
      });
      _addLog('Found ${readers.length} reader(s): ${readers.join(', ')}');
    } catch (e) {
      _addLog('Error listing readers: $e');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<void> _connect() async {
    if (_selectedReader == null) return;
    setState(() => _isBusy = true);
    try {
      final success = await _smartCard.connect(_selectedReader!);
      setState(() => _isConnected = success);
      _addLog(success ? 'Connected to $_selectedReader' : 'Failed to connect');
    } catch (e) {
      _addLog('Error connecting: $e');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _isBusy = true);
    try {
      await _smartCard.disconnect();
      setState(() {
        _isConnected = false;
        _cardholderName = null;
        _cardNumber = null;
        _expiryDate = null;
        _applicationLabel = null;
      });
      _addLog('Disconnected');
    } catch (e) {
      _addLog('Error disconnecting: $e');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  /// Parse TLV: returns (tag, value, bytesConsumed) or null
  (int, Uint8List, int)? _parseTlv(Uint8List data, int offset) {
    if (offset >= data.length) return null;

    int pos = offset;

    // Parse tag
    int tag = data[pos++];
    if (pos > data.length) return null;

    // Multi-byte tag: first byte has lower 5 bits all set
    if ((tag & 0x1F) == 0x1F) {
      while (pos < data.length) {
        tag = (tag << 8) | data[pos++];
        // Last tag byte has bit 7 clear
        if ((data[pos - 1] & 0x80) == 0) break;
      }
    }

    if (pos >= data.length) return null;

    // Parse length
    int length = data[pos++];
    if (length == 0x81) {
      if (pos >= data.length) return null;
      length = data[pos++];
    } else if (length == 0x82) {
      if (pos + 1 >= data.length) return null;
      length = (data[pos] << 8) | data[pos + 1];
      pos += 2;
    } else if (length > 0x82) {
      return null; // Unsupported length encoding
    }

    if (pos + length > data.length) {
      // Truncated - take what we can
      length = data.length - pos;
    }

    final value = data.sublist(pos, pos + length);
    return (tag, value, pos + length);
  }

  /// Walk all TLV elements and collect (tag, value) pairs, recursing into constructed tags
  List<(int, Uint8List)> _parseTlvAll(Uint8List data) {
    final results = <(int, Uint8List)>[];
    int offset = 0;
    while (offset < data.length) {
      final result = _parseTlv(data, offset);
      if (result == null) break;
      final (tag, value, nextOffset) = result;
      results.add((tag, value));

      // Recurse into constructed tags (bit 5 set in first byte)
      final firstByte = tag > 0xFF ? (tag >> 8) & 0xFF : tag;
      if (firstByte & 0x20 != 0) {
        results.addAll(_parseTlvAll(value));
      }

      offset = nextOffset;
    }
    return results;
  }

  /// Find first value for a given tag in TLV data (recursive)
  Uint8List? _findTag(Uint8List data, int targetTag) {
    for (final (tag, value) in _parseTlvAll(data)) {
      if (tag == targetTag) return value;
    }
    return null;
  }

  /// Decode BCD-encoded bytes to string
  String _bcdToString(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Mask a PAN for display (show first 4 and last 4)
  String _maskPan(String pan) {
    pan = pan.replaceAll(RegExp(r'[fF]+$'), '');
    if (pan.length <= 8) return pan;
    return '${pan.substring(0, 4)} **** **** ${pan.substring(pan.length - 4)}';
  }

  Future<void> _readCreditCard() async {
    if (!_isConnected) return;
    setState(() {
      _isBusy = true;
      _cardholderName = null;
      _cardNumber = null;
      _expiryDate = null;
      _applicationLabel = null;
    });

    try {
      _addLog('--- Reading Credit Card ---');

      List<Uint8List> aids = [];
      List<String> labels = [];

      // Step 1: Try SELECT PSE "1PAY.SYS.DDF01"
      _addLog('Step 1: Selecting PSE...');
      final pse = '1PAY.SYS.DDF01'.codeUnits;
      var response = await _transmitApdu([
        0x00, 0xA4, 0x04, 0x00, pse.length, ...pse, 0x00,
      ]);

      if (_isSuccess(response)) {
        _addLog('PSE selected, reading directory...');
        final fci = _data(response);

        // Find SFI (tag 88) in PSE FCI
        final sfi = _findTag(fci, 0x88);
        if (sfi != null && sfi.isNotEmpty) {
          final sfiVal = sfi[0];
          _addLog('PSE SFI: $sfiVal');
          for (int rec = 1; rec <= 10; rec++) {
            try {
              final recResp = await _transmitApdu([
                0x00, 0xB2, rec, (sfiVal << 3) | 0x04, 0x00,
              ]);
              if (!_isSuccess(recResp)) break;
              final recData = _data(recResp);
              final aid = _findTag(recData, 0x4F);
              if (aid != null) {
                aids.add(aid);
                final label = _findTag(recData, 0x50);
                labels.add(label != null ? String.fromCharCodes(label) : 'Unknown');
                _addLog('Found AID: ${_hex(aid)} (${labels.last})');
              }
            } catch (_) {
              break;
            }
          }
        } else {
          _addLog('No SFI in PSE response');
        }
      } else {
        final (sw1, sw2) = _sw(response);
        _addLog('PSE failed (SW=${sw1.toRadixString(16).padLeft(2, '0')} ${sw2.toRadixString(16).padLeft(2, '0')})');
      }

      // Step 2: If no AIDs from PSE, try known AIDs directly
      if (aids.isEmpty) {
        _addLog('Step 2: Trying known payment AIDs...');
        final knownAids = <(String, List<int>)>[
          ('Mastercard', [0xA0, 0x00, 0x00, 0x00, 0x04, 0x10, 0x10]),
          ('Mastercard (alt)', [0xA0, 0x00, 0x00, 0x00, 0x04, 0x10, 0x10, 0x01]),
          ('Visa', [0xA0, 0x00, 0x00, 0x00, 0x03, 0x10, 0x10]),
          ('Visa Electron', [0xA0, 0x00, 0x00, 0x00, 0x03, 0x20, 0x10]),
          ('Maestro', [0xA0, 0x00, 0x00, 0x00, 0x04, 0x30, 0x60]),
          ('Amex', [0xA0, 0x00, 0x00, 0x00, 0x25, 0x01]),
          ('Discover', [0xA0, 0x00, 0x00, 0x03, 0x24, 0x10, 0x10]),
          ('UnionPay', [0xA0, 0x00, 0x00, 0x03, 0x33, 0x01, 0x01]),
        ];

        for (final (name, aid) in knownAids) {
          _addLog('Trying $name: ${_hex(aid)}');
          // Try SELECT with Le
          response = await _transmitApdu([
            0x00, 0xA4, 0x04, 0x00, aid.length, ...aid, 0x00,
          ]);
          if (_isSuccess(response)) {
            aids.add(Uint8List.fromList(aid));
            labels.add(name);
            _addLog('$name selected successfully!');
            break;
          }

          // Try SELECT without Le (Case 3 APDU)
          response = await _transmitApdu([
            0x00, 0xA4, 0x04, 0x00, aid.length, ...aid,
          ]);
          if (_isSuccess(response)) {
            aids.add(Uint8List.fromList(aid));
            labels.add(name);
            _addLog('$name selected successfully (no Le)!');
            break;
          }

          _addLog('$name: SW=${_hex(response.sublist(response.length - 2))}');
        }
      }

      if (aids.isEmpty) {
        _addLog('No payment application found on card');
        setState(() => _isBusy = false);
        return;
      }

      // Step 3: SELECT the first found AID
      _addLog('Step 3: Selecting application...');
      final selectedAid = aids.first;

      // Re-select the AID (in case PSE selection changed state)
      response = await _transmitApdu([
        0x00, 0xA4, 0x04, 0x00, selectedAid.length, ...selectedAid, 0x00,
      ]);

      if (!_isSuccess(response)) {
        // Try without Le
        response = await _transmitApdu([
          0x00, 0xA4, 0x04, 0x00, selectedAid.length, ...selectedAid,
        ]);
      }

      if (!_isSuccess(response)) {
        _addLog('Failed to select application');
        setState(() => _isBusy = false);
        return;
      }

      final fci = _data(response);
      _addLog('Application FCI: ${_hex(fci)}');

      // Extract label from FCI or use the one from PSE
      final label = _findTag(fci, 0x50);
      setState(() {
        _applicationLabel = label != null
            ? String.fromCharCodes(label)
            : labels.first;
      });
      _addLog('Application: $_applicationLabel');

      // Step 4: GET PROCESSING OPTIONS
      _addLog('Step 4: GET PROCESSING OPTIONS...');

      // Extract PDOL (tag 9F38) to know what data the card expects
      final pdol = _findTag(fci, 0x9F38);

      Uint8List gpoResponse;
      if (pdol != null && pdol.isNotEmpty) {
        // Build PDOL data with zeroes (we don't have terminal data)
        int pdolLen = _calculatePdolLength(pdol);
        _addLog('PDOL found, total data length: $pdolLen');
        final pdolData = List<int>.filled(pdolLen, 0x00);
        gpoResponse = await _transmitApdu([
          0x80, 0xA8, 0x00, 0x00,
          pdolData.length + 2,
          0x83, pdolData.length,
          ...pdolData,
          0x00,
        ]);
      } else {
        _addLog('No PDOL, sending empty GPO');
        gpoResponse = await _transmitApdu([
          0x80, 0xA8, 0x00, 0x00, 0x02, 0x83, 0x00, 0x00,
        ]);
      }

      if (!_isSuccess(gpoResponse)) {
        final (sw1, sw2) = _sw(gpoResponse);
        _addLog('GPO failed (SW=${sw1.toRadixString(16).padLeft(2, '0')} ${sw2.toRadixString(16).padLeft(2, '0')})');

        // Try alternative GPO with terminal country/currency data if PDOL required it
        if (sw1 == 0x69 && pdol != null) {
          _addLog('Retrying GPO with populated PDOL...');
          final pdolData = _buildPdolData(pdol);
          gpoResponse = await _transmitApdu([
            0x80, 0xA8, 0x00, 0x00,
            pdolData.length + 2,
            0x83, pdolData.length,
            ...pdolData,
            0x00,
          ]);
        }
      }

      if (!_isSuccess(gpoResponse)) {
        _addLog('GPO failed, trying to read records directly...');
        // Some cards allow reading records without GPO
        await _readRecordsBruteForce();
        _addLog('--- Done ---');
        setState(() => _isBusy = false);
        return;
      }

      _addLog('GPO success');
      final gpoData = _data(gpoResponse);
      _addLog('GPO data: ${_hex(gpoData)}');

      // Parse AFL from GPO response
      Uint8List? afl;

      // Format 2 (tag 77): contains individual TLV tags
      final aflTag94 = _findTag(gpoData, 0x94);
      if (aflTag94 != null) {
        afl = aflTag94;
      }

      // Format 1 (tag 80): AIP (2 bytes) + AFL
      if (afl == null) {
        final tag80 = _findTag(gpoData, 0x80);
        if (tag80 != null && tag80.length > 2) {
          afl = tag80.sublist(2);
        }
      }

      // Also try to extract card data directly from GPO response (some cards include it)
      _extractCardInfo(gpoData);

      // Step 5: READ RECORDS from AFL
      if (afl != null && afl.length >= 4) {
        _addLog('Step 5: Reading ${afl.length ~/ 4} file(s)...');
        for (int i = 0; i < afl.length; i += 4) {
          final sfi = afl[i] >> 3;
          final firstRec = afl[i + 1];
          final lastRec = afl[i + 2];

          for (int rec = firstRec; rec <= lastRec; rec++) {
            try {
              final readResp = await _transmitApdu([
                0x00, 0xB2, rec, (afl[i] & 0xF8) | 0x04, 0x00,
              ]);
              if (!_isSuccess(readResp)) continue;

              final recordData = _data(readResp);
              _extractCardInfo(recordData);
            } catch (e) {
              _addLog('Record SFI=$sfi Rec=$rec error: $e');
            }
          }
        }
      } else {
        _addLog('No AFL found, trying brute force record reading...');
        await _readRecordsBruteForce();
      }

      _addLog('--- Done ---');
    } catch (e) {
      _addLog('Error: $e');
    } finally {
      setState(() => _isBusy = false);
    }
  }

  /// Calculate total PDOL data length from PDOL tag list
  int _calculatePdolLength(Uint8List pdol) {
    int total = 0;
    int i = 0;
    while (i < pdol.length) {
      // Skip tag byte(s)
      if ((pdol[i] & 0x1F) == 0x1F) {
        i++; // Multi-byte tag
        while (i < pdol.length && (pdol[i] & 0x80) != 0) {
          i++;
        }
      }
      i++; // Past last tag byte
      // Read length
      if (i < pdol.length) {
        total += pdol[i];
        i++;
      }
    }
    return total;
  }

  /// Build PDOL data with some sensible defaults for common tags
  List<int> _buildPdolData(Uint8List pdol) {
    final data = <int>[];
    int i = 0;
    while (i < pdol.length) {
      int tag = pdol[i];
      i++;
      if ((tag & 0x1F) == 0x1F) {
        tag = (tag << 8) | pdol[i];
        i++;
      }
      final len = pdol[i];
      i++;

      // Fill with sensible defaults for known tags
      switch (tag) {
        case 0x9F66: // Terminal Transaction Qualifiers
          data.addAll(List.filled(len, 0x00));
          if (len >= 4) {
            data[data.length - len] = 0x26; // Contact chip
            data[data.length - len + 1] = 0x00;
            data[data.length - len + 2] = 0x00;
            data[data.length - len + 3] = 0x00;
          }
          break;
        case 0x9F02: // Amount Authorized
          data.addAll([0x00, 0x00, 0x00, 0x00, 0x00, 0x01].take(len));
          break;
        case 0x9F03: // Amount Other
          data.addAll(List.filled(len, 0x00));
          break;
        case 0x9F1A: // Terminal Country Code
          data.addAll([0x06, 0x16].take(len)); // Poland
          break;
        case 0x5F2A: // Transaction Currency Code
          data.addAll([0x09, 0x85].take(len)); // PLN
          break;
        case 0x9A: // Transaction Date
          data.addAll([0x26, 0x02, 0x19].take(len));
          break;
        case 0x9C: // Transaction Type
          data.addAll([0x00].take(len));
          break;
        case 0x9F37: // Unpredictable Number
          data.addAll(List.filled(len, 0x42));
          break;
        case 0x9F35: // Terminal Type
          data.addAll([0x22].take(len));
          break;
        case 0x9F45: // Data Authentication Code
          data.addAll(List.filled(len, 0x00));
          break;
        default:
          data.addAll(List.filled(len, 0x00));
      }
    }
    return data;
  }

  /// Try to read records by iterating common SFI/record combinations
  Future<void> _readRecordsBruteForce() async {
    for (int sfi = 1; sfi <= 10; sfi++) {
      for (int rec = 1; rec <= 5; rec++) {
        try {
          final resp = await _transmitApdu([
            0x00, 0xB2, rec, (sfi << 3) | 0x04, 0x00,
          ]);
          if (!_isSuccess(resp)) continue;
          final data = _data(resp);
          _extractCardInfo(data);
        } catch (_) {
          continue;
        }
      }
    }
  }

  /// Extract card information from TLV data
  void _extractCardInfo(Uint8List data) {
    // Cardholder Name (tag 5F20)
    if (_cardholderName == null) {
      final name = _findTag(data, 0x5F20);
      if (name != null) {
        final nameStr = String.fromCharCodes(name).trim();
        if (nameStr.isNotEmpty && nameStr != '/') {
          setState(() => _cardholderName = nameStr.replaceAll('/', ' ').trim());
          _addLog('Cardholder: $_cardholderName');
        }
      }
    }

    // PAN (tag 5A)
    if (_cardNumber == null) {
      final pan = _findTag(data, 0x5A);
      if (pan != null) {
        final panStr = _bcdToString(pan);
        setState(() => _cardNumber = _maskPan(panStr));
        _addLog('PAN: $_cardNumber');
      }
    }

    // PAN from track 2 equivalent (tag 57)
    if (_cardNumber == null) {
      final track2 = _findTag(data, 0x57);
      if (track2 != null) {
        final track2Str = _bcdToString(track2);
        // PAN is before the 'D' separator
        final dIdx = track2Str.indexOf('d');
        if (dIdx > 0) {
          final panStr = track2Str.substring(0, dIdx);
          setState(() => _cardNumber = _maskPan(panStr));
          _addLog('PAN (from Track2): $_cardNumber');

          // Expiry from track 2 (4 digits after D: YYMM)
          if (_expiryDate == null && track2Str.length > dIdx + 4) {
            final expYYMM = track2Str.substring(dIdx + 1, dIdx + 5);
            setState(() {
              _expiryDate = '${expYYMM.substring(2, 4)}/${expYYMM.substring(0, 2)}';
            });
            _addLog('Expiry (from Track2): $_expiryDate');
          }
        }
      }
    }

    // Expiry Date (tag 5F24) - YYMMDD
    if (_expiryDate == null) {
      final expiry = _findTag(data, 0x5F24);
      if (expiry != null && expiry.length >= 2) {
        final expiryStr = _bcdToString(expiry);
        if (expiryStr.length >= 4) {
          setState(() {
            _expiryDate = '${expiryStr.substring(2, 4)}/${expiryStr.substring(0, 2)}';
          });
          _addLog('Expiry: $_expiryDate');
        }
      }
    }

    // Application label (tag 50)
    if (_applicationLabel == null) {
      final label = _findTag(data, 0x50);
      if (label != null) {
        setState(() => _applicationLabel = String.fromCharCodes(label));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Card Reader'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Reader selection
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Readers', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            value: _selectedReader,
                            isExpanded: true,
                            hint: const Text('No readers found'),
                            items: _readers
                                .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                                .toList(),
                            onChanged: (v) => setState(() => _selectedReader = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _isBusy ? null : _listReaders,
                          child: const Text('Scan'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Actions
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Actions', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton(
                          onPressed: _isBusy || _isConnected || _selectedReader == null
                              ? null
                              : _connect,
                          child: const Text('Connect'),
                        ),
                        ElevatedButton(
                          onPressed: _isBusy || !_isConnected ? null : _disconnect,
                          child: const Text('Disconnect'),
                        ),
                        FilledButton.icon(
                          onPressed: _isBusy || !_isConnected ? null : _readCreditCard,
                          icon: const Icon(Icons.credit_card),
                          label: const Text('Read Card'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Card info
            if (_cardNumber != null || _cardholderName != null)
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_applicationLabel != null)
                        Text(
                          _applicationLabel!,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                        ),
                      if (_cardNumber != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _cardNumber!,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontFamily: 'monospace',
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (_cardholderName != null)
                            Text(
                              _cardholderName!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                          if (_expiryDate != null)
                            Text(
                              _expiryDate!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            // Status
            Row(
              children: [
                Icon(
                  _isConnected ? Icons.circle : Icons.circle_outlined,
                  color: _isConnected ? Colors.green : Colors.grey,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(_isConnected ? 'Connected' : 'Disconnected'),
                if (_isBusy) ...[
                  const SizedBox(width: 16),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            // Log
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Log', style: Theme.of(context).textTheme.titleMedium),
                          TextButton(
                            onPressed: () => setState(() => _log.clear()),
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                      Expanded(
                        child: ListView.builder(
                          reverse: true,
                          itemCount: _log.length,
                          itemBuilder: (context, index) {
                            final logIndex = _log.length - 1 - index;
                            return Text(
                              _log[logIndex],
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
