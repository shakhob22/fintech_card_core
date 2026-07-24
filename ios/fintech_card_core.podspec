#
# fintech_card_core.podspec
#
Pod::Spec.new do |s|
  s.name             = 'fintech_card_core'
  s.version          = '0.1.0'
  s.summary          = 'Headless Flutter plugin for NFC/OCR payment card reading.'
  s.description      = <<-DESC
    Provides a CardReaderController that unifies NFC (EMV/ISO 7816), on-device
    TFLite OCR, manual entry, and mock-testing in a single headless API. The iOS
    native layer is a thin CoreNFC bridge; APDU/EMV and card OCR run in Dart.
  DESC

  s.homepage         = 'https://github.com/example/fintech_card_core'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency         'Flutter'
  s.platform         = :ios, '13.0'

  # CoreNFC — required for NFCTagReaderSession (ISO 14443 / EMV cards)
  s.frameworks       = 'CoreNFC'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE'                   => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }

  s.swift_version = '5.5'

  s.resource_bundles = {
    'fintech_card_core_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }
end
