//
//  OcrDD.swift
//  CardScan
//
//  Created by xaen on 4/14/20.
//
import CoreGraphics
import Foundation
import UIKit

@available(iOS 11.2, *)
@available(*, deprecated, message: "Replaced by stripe card scan. See https://github.com/stripe/stripe-ios/tree/master/StripeCardScan")
public class OcrDD{
    public var lastDetectedBoxes: [CGRect] = []
    var ssdOcr = SSDOcrDetect()
    public init() { }

    static func configure(){
        // Load priors + touch the model on a throwaway instance. Avoid UIKit
        // drawing here — warmUp() used UIGraphics and is unsafe off-main.
        SSDOcrDetect.initializeModels()
        let probe = SSDOcrDetect()
        if probe.ssdOcrModel == nil {
            NSLog("[OcrDD] configure: SSD OCR model failed to load")
        }
    }

    public func perform(croppedCardImage: CGImage) -> String?{
        let number = ssdOcr.predict(image: UIImage(cgImage: croppedCardImage))
        self.lastDetectedBoxes = ssdOcr.lastDetectedBoxes
        return number
    }

}
