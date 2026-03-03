## 0.2.0

- Added example for extracting DDD files from tachograph driver cards
- `TachographCardReader` reads G1 and G2 tachograph DFs and assembles a standards-compliant DDD byte buffer
- Parses `EF_Identification` to extract driver info (name, birth date, card number, issuing authority)
- Progress callbacks for tracking EF read progress
- Supports both RSA (G1) and ECDSA (G2) signatures

## 0.1.0

- Initial release
- Smart card reader communication for Android, macOS, and Windows
- Android: USB Host CCID protocol
- macOS: CryptoTokenKit framework
- Windows: WinSCard API
