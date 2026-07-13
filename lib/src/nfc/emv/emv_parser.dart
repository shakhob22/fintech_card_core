import 'emv_tags.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TLV Object
// ─────────────────────────────────────────────────────────────────────────────

/// A single TLV (Tag-Length-Value) node in an EMV data object.
class TlvObject {
  final int tag;
  final List<int> value;

  /// Recursively parsed children (populated when this is a constructed tag).
  final List<TlvObject> children;

  const TlvObject({
    required this.tag,
    required this.value,
    this.children = const [],
  });

  bool get isConstructed => children.isNotEmpty;

  String get tagHex => tag.toRadixString(16).toUpperCase().padLeft(
        tag > 0xFF ? 4 : 2,
        '0',
      );

  @override
  String toString() => 'TLV(tag=0x$tagHex, len=${value.length}'
      '${isConstructed ? ', children=${children.length}' : ''})';
}

// ─────────────────────────────────────────────────────────────────────────────
// EMV TLV Parser
// ─────────────────────────────────────────────────────────────────────────────

/// Parses raw EMV TLV byte streams and extracts card data fields.
///
/// The parser follows the BER-TLV encoding rules defined in ISO 7816-4 and
/// EMV Book 3. All APDU response buffers returned by [NfcBridge.transceive]
/// are processed here — no native code is involved.
abstract final class EmvParser {
  // ── Core TLV parser ───────────────────────────────────────────────────────

  /// Parse a flat byte buffer into a list of [TlvObject] nodes.
  static List<TlvObject> parseTlv(List<int> data) {
    final result = <TlvObject>[];
    int i = 0;

    while (i < data.length) {
      // ── Tag field ──────────────────────────────────────────────────────
      if (data[i] == 0x00) { i++; continue; } // padding byte

      int tag = data[i++];
      if ((tag & 0x1F) == 0x1F) {
        // Multi-byte tag — bit 8 of each subsequent byte signals continuation
        do {
          if (i >= data.length) return result;
          tag = (tag << 8) | data[i++];
        } while ((data[i - 1] & 0x80) != 0);
      }

      if (i >= data.length) break;

      // ── Length field ───────────────────────────────────────────────────
      final lenByte = data[i++];
      int length;
      if (lenByte <= 0x7F) {
        length = lenByte;
      } else if (lenByte == 0x81) {
        if (i >= data.length) break;
        length = data[i++];
      } else if (lenByte == 0x82) {
        if (i + 1 >= data.length) break;
        length = (data[i] << 8) | data[i + 1];
        i += 2;
      } else {
        break; // unsupported definite-form length
      }

      if (i + length > data.length) break;

      // ── Value field ────────────────────────────────────────────────────
      final value = data.sublist(i, i + length);
      i += length;

      // Determine constructed vs primitive from bit 6 of the first tag byte
      final firstByte = tag > 0xFF ? (tag >> 8) & 0xFF : tag;
      final isConstructed = (firstByte & 0x20) != 0;

      result.add(TlvObject(
        tag: tag,
        value: value,
        children: isConstructed ? parseTlv(value) : [],
      ));
    }

    return result;
  }

  // ── Search ────────────────────────────────────────────────────────────────

  /// Depth-first search for [tag] inside [tlvList] (includes nested children).
  static TlvObject? findTag(List<TlvObject> tlvList, int tag) {
    for (final node in tlvList) {
      if (node.tag == tag) return node;
      final found = findTag(node.children, tag);
      if (found != null) return found;
    }
    return null;
  }

  // ── Card data extractors ──────────────────────────────────────────────────

  /// Extract the PAN from tag 0x5A (BCD-encoded, padded with trailing 0xF).
  static String? extractPan(List<TlvObject> tlvList) {
    final node = findTag(tlvList, EmvTags.pan);
    if (node == null) return null;
    final hex = node.value
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    // Remove trailing 'F' padding
    return hex.replaceAll(RegExp(r'F+$'), '');
  }

  /// Extract PAN from Track 2 Equivalent Data (tag 0x57).
  /// Format: `PAN D YYMM ServiceCode Discretionary FF…`
  static String? extractPanFromTrack2(List<TlvObject> tlvList) {
    final node = findTag(tlvList, EmvTags.track2EquivalentData);
    if (node == null) return null;
    final hex = node.value
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    final separatorIdx = hex.indexOf('D');
    if (separatorIdx < 0) return null;
    return hex.substring(0, separatorIdx);
  }

  /// Extract expiry date from tag 0x5F24 (YYMMDD BCD) → `MM/YY` string.
  static String? extractExpiryDate(List<TlvObject> tlvList) {
    final node = findTag(tlvList, EmvTags.expiryDate);
    if (node == null) return null;
    final hex = node.value
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (hex.length < 6) return null;
    final yy = hex.substring(0, 2);
    final mm = hex.substring(2, 4);
    return '$mm/$yy';
  }

  /// Extract expiry from Track 2 Equivalent Data.
  static String? extractExpiryFromTrack2(List<TlvObject> tlvList) {
    final node = findTag(tlvList, EmvTags.track2EquivalentData);
    if (node == null) return null;
    final hex = node.value
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    final dIdx = hex.indexOf('D');
    if (dIdx < 0 || dIdx + 4 >= hex.length) return null;
    final yy = hex.substring(dIdx + 1, dIdx + 3);
    final mm = hex.substring(dIdx + 3, dIdx + 5);
    return '$mm/$yy';
  }

  /// Extract cardholder name from tag 0x5F20 (ISO 8859-1 encoded).
  static String? extractCardholderName(List<TlvObject> tlvList) {
    final node = findTag(tlvList, EmvTags.cardholderName);
    if (node == null) return null;
    return String.fromCharCodes(node.value).trim();
  }

  /// Extract the AID (Application Identifier) from tag 0x84.
  static List<int>? extractAid(List<TlvObject> tlvList) {
    return findTag(tlvList, EmvTags.applicationId)?.value;
  }

  /// Parse AFL (Application File Locator) from tag 0x94.
  /// Returns a list of `{sfi, record}` maps describing which records to read.
  static List<Map<String, int>> extractAfl(List<TlvObject> tlvList) {
    final node = findTag(tlvList, EmvTags.afl);
    if (node == null) return [];
    final records = <Map<String, int>>[];
    final d = node.value;
    for (int i = 0; i + 3 < d.length; i += 4) {
      final sfi = (d[i] >> 3) & 0x1F;
      final first = d[i + 1];
      final last = d[i + 2];
      for (int r = first; r <= last; r++) {
        records.add({'sfi': sfi, 'record': r});
      }
    }
    return records;
  }

  /// Build the data field for GET PROCESSING OPTIONS from a PDOL node.
  ///
  /// The PDOL (tag 0x9F38) is a list of `[tag… | length]` pairs that
  /// describes which data elements the card expects. Since this is a read-only
  /// flow (no transaction amount, PIN, etc.) we fill every element with zeros
  /// of the correct length, then wrap in the required 0x83 template tag.
  ///
  /// Returns `[0x83, totalLen, 0x00 × totalLen]` — ready to use as the
  /// `data` field of [ApduCommand.getProcessingOptions].
  static List<int> buildPdolData(TlvObject pdolNode) {
    final bytes = pdolNode.value;
    int totalLength = 0;
    int i = 0;
    while (i < bytes.length) {
      // Tag: consume 1 or 2 bytes
      if (i >= bytes.length) break;
      final firstTagByte = bytes[i++];
      if ((firstTagByte & 0x1F) == 0x1F) {
        // Multi-byte tag — consume continuation bytes
        while (i < bytes.length && (bytes[i] & 0x80) != 0) {
          i++;
        }
        if (i < bytes.length) i++; // last tag byte (no continuation bit)
      }
      // Length byte
      if (i >= bytes.length) break;
      totalLength += bytes[i++];
    }
    return [0x83, totalLength, ...List.filled(totalLength, 0x00)];
  }

  /// Parse AFL from a Format 1 GPO response (tag 0x80).
  /// Layout: `[AIP (2 bytes) | AFL (n×4 bytes)]`
  static List<Map<String, int>> extractAflFromTemplate1(List<TlvObject> tlvList) {
    final node = findTag(tlvList, EmvTags.responseTemplate1);
    if (node == null || node.value.length < 6) return [];
    final aflData = node.value.sublist(2); // skip AIP
    final records = <Map<String, int>>[];
    for (int i = 0; i + 3 < aflData.length; i += 4) {
      final sfi = (aflData[i] >> 3) & 0x1F;
      final first = aflData[i + 1];
      final last = aflData[i + 2];
      for (int r = first; r <= last; r++) {
        records.add({'sfi': sfi, 'record': r});
      }
    }
    return records;
  }
}
