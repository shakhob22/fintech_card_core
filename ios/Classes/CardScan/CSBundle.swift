//
//  CardScan.swift
//  CardScan
//
//  Adapted for fintech_card_core Flutter plugin — looks up SSDOcr.mlmodelc in
//  the plugin / host bundle (no CardScan.bundle / UI packaging).
//

import Foundation

@available(*, deprecated, message: "Replaced by stripe card scan. See https://github.com/stripe/stripe-ios/tree/master/StripeCardScan")
public class CSBundle {
    public static var bundleIdentifier = "com.example.fintechCardCore"
    public static var cardScanBundle: Bundle?
    public static var namedBundle = "fintech_card_core_cardscan"
    public static var namedBundleExtension = "bundle"

    public static func bundle() -> Bundle? {
        if let cardScanBundle {
            return cardScanBundle
        }

        if let bundle = Bundle(identifier: bundleIdentifier) {
            return bundle
        }

        let host = Bundle(for: CSBundle.self)
        if let url = host.url(forResource: namedBundle, withExtension: namedBundleExtension),
           let named = Bundle(url: url) {
            return named
        }

        return host
    }

    static func compiledModel(forResource: String, withExtension: String) -> URL? {
        var candidates: [Bundle] = [
            cardScanBundle,
            Bundle(for: CSBundle.self),
            Bundle.main,
            bundle(),
        ].compactMap { $0 }

        // Also search every framework in the app for the nested resource bundle
        // (Flutter embeds plugin resources under *.framework/).
        if let frameworks = Bundle.main.privateFrameworksURL,
           let urls = try? FileManager.default.contentsOfDirectory(
            at: frameworks,
            includingPropertiesForKeys: nil
           ) {
            for url in urls where url.pathExtension == "framework" {
                if let fb = Bundle(url: url) {
                    candidates.append(fb)
                }
            }
        }

        for candidate in candidates {
            if let url = candidate.url(forResource: forResource, withExtension: withExtension) {
                return url
            }
            // Resource-bundle layout: Model.mlmodelc inside a .bundle
            if let nested = candidate.url(forResource: namedBundle, withExtension: namedBundleExtension),
               let nestedBundle = Bundle(url: nested),
               let url = nestedBundle.url(forResource: forResource, withExtension: withExtension) {
                return url
            }
        }

        print("Could not find CoreML model \"\(forResource).\(withExtension)\"")
        return nil
    }
}
