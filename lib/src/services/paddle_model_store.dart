import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Copies bundled Paddle Lite (`.nb`) models from package assets to a writable
/// directory — Paddle Lite needs real filesystem paths.
class PaddleModelStore {
  PaddleModelStore._();
  static final instance = PaddleModelStore._();

  static const _assetPrefix =
      'packages/fintech_card_core/assets/models/paddle';

  static const detAsset = '$_assetPrefix/det_db.nb';
  static const recAsset = '$_assetPrefix/rec_crnn.nb';
  static const clsAsset = '$_assetPrefix/cls.nb';
  static const dictAsset = '$_assetPrefix/ppocr_keys_v1.txt';

  Directory? _dir;
  bool _ready = false;

  bool get isReady => _ready;

  String get detPath => '${_dir!.path}/det_db.nb';
  String get recPath => '${_dir!.path}/rec_crnn.nb';
  String get clsPath => '${_dir!.path}/cls.nb';
  String get dictPath => '${_dir!.path}/ppocr_keys_v1.txt';

  /// Ensures models exist on disk (offline — from bundled assets only).
  Future<void> ensureReady() async {
    if (_ready) return;

    final support = await getApplicationSupportDirectory();
    _dir = Directory('${support.path}/paddle_ocr_v2')
      ..createSync(recursive: true);

    await Future.wait([
      _copyIfNeeded(detAsset, detPath),
      _copyIfNeeded(recAsset, recPath),
      _copyIfNeeded(clsAsset, clsPath),
      _copyIfNeeded(dictAsset, dictPath),
    ]);

    _ready = true;
  }

  Future<void> _copyIfNeeded(String asset, String destPath) async {
    final dest = File(destPath);
    if (dest.existsSync() && dest.lengthSync() > 0) return;

    final data = await rootBundle.load(asset);
    await dest.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }
}
