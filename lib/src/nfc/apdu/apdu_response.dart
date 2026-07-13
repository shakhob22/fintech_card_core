/// Parsed ISO 7816-4 APDU response.
///
/// Raw layout: `[Data bytes… | SW1 | SW2]`
/// The last two bytes are always the Status Word (SW1 SW2).
class ApduResponse {
  /// Data payload returned by the card (everything except the status word).
  final List<int> data;

  /// Status Word byte 1.
  final int sw1;

  /// Status Word byte 2.
  final int sw2;

  const ApduResponse({
    required this.data,
    required this.sw1,
    required this.sw2,
  });

  // ── Status helpers ────────────────────────────────────────────────────────

  /// Combined 16-bit status word (SW1 << 8 | SW2).
  int get statusWord => (sw1 << 8) | sw2;

  /// `true` when SW = 0x9000 (normal completion).
  bool get isSuccess => sw1 == 0x90 && sw2 == 0x00;

  /// `true` when SW1 = 0x61 — card has [bytesAvailable] more bytes to send.
  bool get needsGetResponse => sw1 == 0x61;

  /// Number of additional bytes available when [needsGetResponse] is `true`.
  int get bytesAvailable => sw2;

  /// `true` when SW1 = 0x62 or 0x63 — warning condition.
  bool get isWarning => sw1 == 0x62 || sw1 == 0x63;

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Parse a raw byte list returned by [NfcBridge.transceive].
  factory ApduResponse.parse(List<int> raw) {
    if (raw.length < 2) {
      throw FormatException(
        'APDU response is too short (${raw.length} byte(s)); minimum is 2.',
      );
    }
    return ApduResponse(
      data: raw.sublist(0, raw.length - 2),
      sw1: raw[raw.length - 2],
      sw2: raw[raw.length - 1],
    );
  }

  // ── Diagnostics ───────────────────────────────────────────────────────────

  String get statusHex =>
      '${sw1.toRadixString(16).padLeft(2, '0').toUpperCase()}'
      '${sw2.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String get statusDescription => switch (statusWord) {
        0x9000 => 'Normal completion',
        0x6700 => 'Wrong length (Lc/Le mismatch)',
        0x6900 => 'Command not allowed',
        0x6981 => 'Command incompatible with file structure',
        0x6982 => 'Security status not satisfied',
        0x6983 => 'Authentication method blocked',
        0x6984 => 'Referenced data invalidated',
        0x6985 => 'Conditions of use not satisfied',
        0x6986 => 'Command not allowed — no current EF',
        0x6A81 => 'Function not supported',
        0x6A82 => 'File not found',
        0x6A83 => 'Record not found',
        0x6A86 => 'Incorrect P1/P2',
        0x6D00 => 'Instruction not supported',
        0x6E00 => 'Class not supported',
        _ => 'Unknown status ($statusHex)',
      };

  @override
  String toString() =>
      'ApduResponse(sw=$statusHex, dataLen=${data.length}, "$statusDescription")';
}
