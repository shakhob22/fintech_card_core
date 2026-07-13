/// Represents an ISO 7816-4 APDU (Application Protocol Data Unit) command.
///
/// Byte structure: `[CLA | INS | P1 | P2 | (Lc | Data) | (Le)]`
///
/// This class mirrors the low-level framing used when sending signals through
/// serial interfaces (e.g. SPI from a microcontroller to a peripheral) — every
/// byte has a strict, positional meaning and must be assembled in exact order.
class ApduCommand {
  /// Class byte — context of the command (ISO / proprietary).
  final int cla;

  /// Instruction byte — identifies the command.
  final int ins;

  /// Parameter byte 1.
  final int p1;

  /// Parameter byte 2.
  final int p2;

  /// Command data payload (optional).
  final List<int>? data;

  /// Expected response length (0x00 = full response). Omitted when null.
  final int? le;

  const ApduCommand({
    required this.cla,
    required this.ins,
    required this.p1,
    required this.p2,
    this.data,
    this.le,
  });

  // ── Serialization ─────────────────────────────────────────────────────────

  /// Serialise to a byte sequence ready for transmission over MethodChannel.
  List<int> toBytes() {
    final cmd = <int>[cla, ins, p1, p2];
    if (data != null && data!.isNotEmpty) {
      cmd.add(data!.length); // Lc
      cmd.addAll(data!);
    }
    if (le != null) cmd.add(le!);
    return cmd;
  }

  // ── EMV named constructors ────────────────────────────────────────────────

  /// SELECT Proximity Payment System Environment (PPSE).
  /// Discovers which payment applications the card supports.
  factory ApduCommand.selectPpse() {
    // "2PAY.SYS.DDF01" in ASCII
    const ppse = [
      0x32, 0x50, 0x41, 0x59, 0x2E, 0x53, 0x59, 0x53,
      0x2E, 0x44, 0x44, 0x46, 0x30, 0x31,
    ];
    return const ApduCommand(
      cla: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00,
      data: ppse, le: 0x00,
    );
  }

  /// SELECT Application by [aid].
  factory ApduCommand.selectApplication(List<int> aid) {
    return ApduCommand(
      cla: 0x00, ins: 0xA4, p1: 0x04, p2: 0x00,
      data: aid, le: 0x00,
    );
  }

  /// GET PROCESSING OPTIONS — initiates the transaction with the given PDOL
  /// data field.
  ///
  /// [pdolData] should be the output of [EmvParser.buildPdolData] when the
  /// card's FCI contains a PDOL (tag 0x9F38). Pass `null` (or omit) to send
  /// an empty PDOL template (`0x83 0x00`), which works for cards that do not
  /// advertise a PDOL.
  factory ApduCommand.getProcessingOptions([List<int>? pdolData]) {
    return ApduCommand(
      cla: 0x80, ins: 0xA8, p1: 0x00, p2: 0x00,
      data: pdolData ?? const [0x83, 0x00],
      le: 0x00,
    );
  }

  /// READ RECORD at [recordNumber] in the SFI (Short File Identifier) [sfi].
  factory ApduCommand.readRecord(int recordNumber, int sfi) {
    return ApduCommand(
      cla: 0x00,
      ins: 0xB2,
      p1: recordNumber,
      p2: (sfi << 3) | 0x04, // P2 encodes the SFI per ISO 7816-4 §7.3.3
      le: 0x00,
    );
  }

  /// GET DATA for [tag] — fetches a specific data object.
  factory ApduCommand.getData(int tag) {
    return ApduCommand(
      cla: 0x80,
      ins: 0xCA,
      p1: (tag >> 8) & 0xFF,
      p2: tag & 0xFF,
      le: 0x00,
    );
  }
}
