#
# fintech_card_core.podspec
#
Pod::Spec.new do |s|
  s.name             = 'fintech_card_core'
  s.version          = '0.1.3'
  s.summary          = 'Headless Flutter plugin for NFC/OCR payment card reading.'
  s.description      = <<-DESC
    Provides a CardReaderController that unifies NFC (EMV/ISO 7816), OCR,
    and manual entry in a single headless API. The iOS native layer is a thin
    CoreNFC bridge plus CardScan SSD CoreML OCR; all APDU/EMV logic runs in Dart.
  DESC

  s.homepage         = 'https://github.com/example/fintech_card_core'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  # Classes/cardcv.cpp is a relay that #includes ../../src/cardcv.cpp — the
  # OpenCV pre-processing core shared with Android and consumed via dart:ffi.
  s.source_files     = 'Classes/**/*'
  s.dependency         'Flutter'
  s.platform         = :ios, '13.0'
  s.library          = 'c++'

  # ── Optional OpenCV pipeline (perspective warp + CLAHE) ────────────────────
  # The stub flavour builds by default (no extra dependencies); the Dart layer
  # detects it via cardcv_available() and falls back to CardScan SSD OCR.
  # To enable the full pipeline, uncomment the two lines below
  # (the OpenCV pod is the free, Apache-2.0 licensed official build):
  #
  # s.dependency 'OpenCV', '~> 4.3'
  # s.compiler_flags = '-DCARDCV_HAS_OPENCV=1'

  # CoreNFC — NFCTagReaderSession (ISO 14443 / EMV cards)
  # CoreML  — CardScan SSD OCR model
  s.frameworks       = 'CoreNFC', 'CoreML', 'UIKit', 'CoreGraphics', 'Accelerate', 'VideoToolbox'

  # Expose NFC capability to the host app's entitlements
  s.pod_target_xcconfig = {
    'DEFINES_MODULE'                   => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }

  s.swift_version = '5.5'

  # Privacy manifest + precompiled CardScan SSD CoreML model.
  # Swift interface is checked in under Classes/CardScan/Generated/SSDOcr.swift.
  s.resource_bundles = {
    'fintech_card_core_privacy' => ['Resources/PrivacyInfo.xcprivacy'],
    'fintech_card_core_cardscan' => ['Classes/CardScan/SSDOcr.mlmodelc'],
  }

  # Avoid compiling the raw .mlmodel (would regenerate a second SSDOcr.swift).
  s.exclude_files = 'Classes/CardScan/SSDOcr.mlmodel'
end
