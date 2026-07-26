//
//  CGrect+utils.swift
//  CardScan
//
//  Created by Jaime Park on 6/11/21.
//

import CoreGraphics

@available(*, deprecated, message: "Replaced by stripe card scan. See https://github.com/stripe/stripe-ios/tree/master/StripeCardScan")
extension CGRect {
    func centerY() -> CGFloat {
        return (minY / 2 + maxY / 2)
    }
    
    func centerX() -> CGFloat {
        return (minX / 2 + maxX / 2)
    }

    /// Intersection-over-union for NMS (from CardScan `CGRectExtension`).
    func iou(nextBox: CGRect) -> Float {
        let areaCurrent = width * height
        if areaCurrent <= 0 {
            return 0
        }

        let areaNext = nextBox.width * nextBox.height
        if areaNext <= 0 {
            return 0
        }

        let intersectionMinX = max(minX, nextBox.minX)
        let intersectionMinY = max(minY, nextBox.minY)
        let intersectionMaxX = min(maxX, nextBox.maxX)
        let intersectionMaxY = min(maxY, nextBox.maxY)
        let intersectionArea = max(intersectionMaxY - intersectionMinY, 0) *
            max(intersectionMaxX - intersectionMinX, 0)
        return Float(intersectionArea / (areaCurrent + areaNext - intersectionArea))
    }
}
