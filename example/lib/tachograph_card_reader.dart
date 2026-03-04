import 'dart:math';
import 'dart:typed_data';

/// Callback for transmitting an APDU and receiving the response.
typedef TransmitCallback = Future<Uint8List> Function(List<int> apdu);

/// Progress callback: current EF name, index (0-based), total count.
typedef ProgressCallback = void Function(String efName, int current, int total);

/// Parsed driver information extracted from the card.
class DriverInfo {
  final String? surname;
  final String? firstName;
  final String? birthDate;
  final String? cardNumber;
  final String? countryCode;
  final String? licenceNumber;
  final String? issuingAuthority;

  DriverInfo({
    this.surname,
    this.firstName,
    this.birthDate,
    this.cardNumber,
    this.countryCode,
    this.licenceNumber,
    this.issuingAuthority,
  });

  String get displayName =>
      [firstName, surname].where((s) => s != null && s.trim().isNotEmpty).join(' ').trim();
}

/// EF definition: file ID, name, expected data size.
class _EfDef {
  final int fid;
  final String name;
  final int size;
  final bool hasSig;

  const _EfDef(this.fid, this.name, this.size, {this.hasSig = true});
}

/// Reads a G2 tachograph driver card and produces a DDD byte buffer.
class TachographCardReader {
  final TransmitCallback _transmit;
  final ProgressCallback? onProgress;

  TachographCardReader(this._transmit, {this.onProgress});

  // -- MF-level EFs (no DF selection needed, no signatures) --
  static const _mfEfs = [
    _EfDef(0x0002, 'EF_ICC', 25, hasSig: false),
    _EfDef(0x0005, 'EF_IC', 8, hasSig: false),
    _EfDef(0x2F00, 'EF_DIR', 20, hasSig: false),
    _EfDef(0x2F01, 'EF_DIR_G2', 11, hasSig: false),
    _EfDef(0x0006, 'EF_ATR', 3, hasSig: false),
  ];

  // -- G1 DF (AID FF 54 41 43 48 4F = "TACHO") --
  static const _g1Aid = [0xFF, 0x54, 0x41, 0x43, 0x48, 0x4F];
  static const _g1Efs = [
    _EfDef(0x0501, 'EF_Application_Identification', 10),
    _EfDef(0xC100, 'EF_CA_Certificate', 194, hasSig: false),
    _EfDef(0xC108, 'EF_Card_Certificate', 194, hasSig: false),
    _EfDef(0x0520, 'EF_Identification', 143),
    _EfDef(0x050E, 'EF_Card_Download', 4),
    _EfDef(0x0521, 'EF_Driving_Licence_Info', 53),
    _EfDef(0x0502, 'EF_Events_Data', 1728),
    _EfDef(0x0503, 'EF_Faults_Data', 1152),
    _EfDef(0x0504, 'EF_Driver_Activity_Data', 13780),
    _EfDef(0x0505, 'EF_Vehicles_Used', 6202),
    _EfDef(0x0506, 'EF_Places', 1121),
    _EfDef(0x0507, 'EF_Current_Usage', 19),
    _EfDef(0x0508, 'EF_Control_Activity_Data', 46),
    _EfDef(0x0522, 'EF_Specific_Conditions', 280),
  ];

  // -- G2 DF (AID FF 53 4D 52 44 54 = "SMRDT") --
  static const _g2Aid = [0xFF, 0x53, 0x4D, 0x52, 0x44, 0x54];
  static const _g2Efs = [
    _EfDef(0x0501, 'EF_Application_Identification_G2', 17),
    _EfDef(0xC100, 'EF_CA_Certificate_G2', 204, hasSig: false),
    _EfDef(0xC108, 'EF_Card_Certificate_G2', 204, hasSig: false),
    _EfDef(0xC101, 'EF_Link_Certificate_G2', 204, hasSig: false),
    _EfDef(0xC109, 'EF_Card_Sign_Certificate_G2', 204, hasSig: false),
    _EfDef(0x0520, 'EF_Identification_G2', 143),
    _EfDef(0x050E, 'EF_Card_Download_G2', 4),
    _EfDef(0x0521, 'EF_Driving_Licence_Info_G2', 53),
    _EfDef(0x0502, 'EF_Events_Data_G2', 3168),
    _EfDef(0x0503, 'EF_Faults_Data_G2', 1152),
    _EfDef(0x0504, 'EF_Driver_Activity_Data_G2', 13780),
    _EfDef(0x0505, 'EF_Vehicles_Used_G2', 9602),
    _EfDef(0x0506, 'EF_Places_G2', 2354),
    _EfDef(0x0507, 'EF_Current_Usage_G2', 19),
    _EfDef(0x0508, 'EF_Control_Activity_Data_G2', 46),
    _EfDef(0x0522, 'EF_Specific_Conditions_G2', 562),
    _EfDef(0x0523, 'EF_VehicleUnits_Used_G2', 2002),
    _EfDef(0x0524, 'EF_GNSS_Places_G2', 6050),
  ];

  static const _g1SigLen = 128; // RSA
  static const _g2SigLen = 64; // ECDSA
  static const _chunkSize = 200;

  /// Read the full tachograph card and return (DDD bytes, DriverInfo).
  Future<(Uint8List, DriverInfo)> read() async {
    final ddd = BytesBuilder(copy: false);
    DriverInfo? driverInfo;

    final totalEfs = _mfEfs.length + _g1Efs.length + _g2Efs.length;
    var currentEf = 0;

    // --- MF-level EFs ---
    for (final ef in _mfEfs) {
      onProgress?.call(ef.name, currentEf, totalEfs);
      await _selectEf(ef.fid);
      final data = await _readBinary(ef.size);
      _writeDddBlock(ddd, ef.fid, 0x00, data); // type 0 = G1/MF data
      currentEf++;
    }

    // --- G1 DF ---
    await _selectDfByAid(_g1Aid);
    for (final ef in _g1Efs) {
      onProgress?.call(ef.name, currentEf, totalEfs);
      await _selectEf(ef.fid);

      if (ef.hasSig) {
        await _performHash();
      }

      final data = await _readBinary(ef.size);
      _writeDddBlock(ddd, ef.fid, 0x00, data); // type 0 = G1 data

      if (ef.hasSig) {
        final sig = await _computeSignature(_g1SigLen);
        _writeDddBlock(ddd, ef.fid, 0x01, sig); // type 1 = G1 signature
      }

      // Parse driver info from G1 EF_Identification
      if (ef.fid == 0x0520) {
        driverInfo = _parseIdentification(data);
      }

      currentEf++;
    }

    // --- G2 DF ---
    await _selectDfByAid(_g2Aid);
    for (final ef in _g2Efs) {
      onProgress?.call(ef.name, currentEf, totalEfs);
      await _selectEf(ef.fid);

      if (ef.hasSig) {
        await _performHash();
      }

      final data = await _readBinary(ef.size);
      _writeDddBlock(ddd, ef.fid, 0x02, data); // type 2 = G2 data

      if (ef.hasSig) {
        final sig = await _computeSignature(_g2SigLen);
        _writeDddBlock(ddd, ef.fid, 0x03, sig); // type 3 = G2 signature
      }

      currentEf++;
    }

    onProgress?.call('Done', totalEfs, totalEfs);
    return (ddd.takeBytes(), driverInfo ?? DriverInfo());
  }

  // -- APDU helpers --

  Future<Uint8List> _selectDfByAid(List<int> aid) async {
    return _transmit([0x00, 0xA4, 0x04, 0x0C, aid.length, ...aid]);
  }

  Future<Uint8List> _selectEf(int fid) async {
    return _transmit([
      0x00, 0xA4, 0x02, 0x0C, 0x02,
      (fid >> 8) & 0xFF, fid & 0xFF,
    ]);
  }

  Future<void> _performHash() async {
    await _transmit([0x80, 0x2A, 0x90, 0x00]);
  }

  Future<Uint8List> _computeSignature(int sigLen) async {
    final resp = await _transmit([0x00, 0x2A, 0x9E, 0x9A, sigLen]);
    // Strip SW1 SW2
    if (resp.length >= 2) {
      return resp.sublist(0, resp.length - 2);
    }
    return resp;
  }

  Future<Uint8List> _readBinary(int expectedSize) async {
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < expectedSize) {
      final toRead = min(_chunkSize, expectedSize - offset);
      final resp = await _transmit([
        0x00, 0xB0,
        (offset >> 8) & 0x7F, offset & 0xFF,
        toRead,
      ]);
      if (resp.length < 2) break;
      // Data = response without SW1 SW2
      final chunk = resp.sublist(0, resp.length - 2);
      if (chunk.isEmpty) break;
      builder.add(chunk);
      offset += chunk.length;
    }
    return builder.takeBytes();
  }

  // -- DDD block writer --

  void _writeDddBlock(BytesBuilder ddd, int tag, int type, Uint8List data) {
    ddd.addByte((tag >> 8) & 0xFF);
    ddd.addByte(tag & 0xFF);
    ddd.addByte(type);
    ddd.addByte((data.length >> 8) & 0xFF);
    ddd.addByte(data.length & 0xFF);
    ddd.add(data);
  }

  // -- Driver info parsing --

  /// Parse EF_Identification (0520) for driver info.
  /// Structure per EU tachograph regulation:
  ///   0       : cardIssuingMemberState (NationNumeric, 1 byte)
  ///   1..16   : cardNumber (16 bytes ASCII)
  ///  17..52   : cardIssuingAuthorityName (1 byte codePage + 35 bytes name)
  ///  53..56   : cardIssueDate (TimeReal, 4 bytes)
  ///  57..60   : cardValidityBegin (TimeReal, 4 bytes)
  ///  61..64   : cardExpiryDate (TimeReal, 4 bytes)
  ///  65..100  : holderSurname (1 byte codePage + 35 bytes name)
  /// 101..136  : holderFirstNames (1 byte codePage + 35 bytes name)
  /// 137..140  : cardHolderBirthDate (4 bytes, BCD YYYYMMDD)
  /// 141..142  : cardHolderPreferredLanguage (2 bytes ASCII)
  DriverInfo _parseIdentification(Uint8List data) {
    if (data.length < 143) return DriverInfo();

    String? cardNumber;
    try {
      cardNumber = String.fromCharCodes(data.sublist(1, 17)).trim();
      if (cardNumber.isEmpty) cardNumber = null;
    } catch (_) {}

    String? countryCode;
    try {
      countryCode = String.fromCharCodes(data.sublist(141, 143)).trim();
      if (countryCode.isEmpty) countryCode = null;
    } catch (_) {}

    String? surname;
    try {
      // Skip codePage byte at offset 65
      surname = String.fromCharCodes(data.sublist(66, 101)).trim();
      if (surname.isEmpty) surname = null;
    } catch (_) {}

    String? firstName;
    try {
      // Skip codePage byte at offset 101
      firstName = String.fromCharCodes(data.sublist(102, 137)).trim();
      if (firstName.isEmpty) firstName = null;
    } catch (_) {}

    String? birthDate;
    try {
      final bcd = data.sublist(137, 141);
      final str = bcd.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (str.length >= 8 && str != '00000000') {
        birthDate = '${str.substring(0, 4)}-${str.substring(4, 6)}-${str.substring(6, 8)}';
      }
    } catch (_) {}

    String? issuingAuthority;
    try {
      // Skip codePage byte at offset 17
      issuingAuthority = String.fromCharCodes(data.sublist(18, 53)).trim();
      if (issuingAuthority.isEmpty) issuingAuthority = null;
    } catch (_) {}

    return DriverInfo(
      surname: surname,
      firstName: firstName,
      birthDate: birthDate,
      cardNumber: cardNumber,
      countryCode: countryCode,
      issuingAuthority: issuingAuthority,
    );
  }
}
