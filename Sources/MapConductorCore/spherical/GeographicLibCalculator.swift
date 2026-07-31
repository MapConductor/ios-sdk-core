import Foundation

/// WGS84 ellipsoid geodesic distance/interpolation via Vincenty's formulae.
///
/// Ported from the android-sdk/react-sdk implementations so all platforms agree
/// without depending on an external geographiclib library. Vincenty can fail to
/// converge for near-antipodal point pairs; in that (rare, map-rendering-
/// irrelevant) case this falls back to a spherical (haversine) approximation,
/// matching android/react behavior exactly.
public enum GeographicLibCalculator {
    private static let flattening = Earth.flattening
    private static let semiMajorAxis = Earth.radiusMeters
    private static let semiMinorAxis = Earth.semiMinorAxisMeters

    private struct InverseResult {
        let distanceMeters: Double
        let initialBearingRad: Double
    }

    public static func computeDistanceBetween(
        from: GeoPointProtocol,
        to: GeoPointProtocol
    ) -> Double {
        inverse(from: from, to: to).distanceMeters
    }

    public static func interpolate(
        from: GeoPointProtocol,
        to: GeoPointProtocol,
        fraction: Double
    ) -> GeoPoint {
        let line = inverse(from: from, to: to)
        let destination = direct(
            origin: from,
            initialBearingRad: line.initialBearingRad,
            distanceMeters: line.distanceMeters * fraction
        )

        let altitude: Double
        switch (from.altitude, to.altitude) {
        case let (fromAlt?, toAlt?):
            altitude = fromAlt + fraction * (toAlt - fromAlt)
        case let (fromAlt?, nil):
            altitude = fromAlt
        case let (nil, toAlt?):
            altitude = toAlt
        default:
            altitude = 0.0
        }

        return GeoPoint(latitude: destination.0, longitude: destination.1, altitude: altitude)
    }

    private static func inverse(
        from: GeoPointProtocol,
        to: GeoPointProtocol
    ) -> InverseResult {
        let lat1 = deg2rad(from.latitude)
        let lat2 = deg2rad(to.latitude)
        let lon1 = deg2rad(from.longitude)
        let lon2 = deg2rad(to.longitude)
        let longitudeDifference = lon2 - lon1

        let u1 = atan((1 - flattening) * tan(lat1))
        let u2 = atan((1 - flattening) * tan(lat2))
        let sinU1 = sin(u1)
        let cosU1 = cos(u1)
        let sinU2 = sin(u2)
        let cosU2 = cos(u2)

        var lambda = longitudeDifference
        var lambdaPrev = 0.0
        var iterLimit = 100
        var cosSqAlpha = 0.0
        var sinSigma = 0.0
        var cos2SigmaM = 0.0
        var cosSigma = 0.0
        var sigma = 0.0

        repeat {
            let sinLambda = sin(lambda)
            let cosLambda = cos(lambda)
            sinSigma = sqrt(
                (cosU2 * sinLambda) * (cosU2 * sinLambda) +
                (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda) *
                (cosU1 * sinU2 - sinU1 * cosU2 * cosLambda)
            )

            if sinSigma == 0.0 {
                return InverseResult(distanceMeters: 0.0, initialBearingRad: 0.0)
            }

            cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            let sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma
            cosSqAlpha = 1 - sinAlpha * sinAlpha
            cos2SigmaM = cosSigma - 2 * sinU1 * sinU2 / cosSqAlpha
            if !cos2SigmaM.isFinite { cos2SigmaM = 0.0 }

            let correctionFactor = flattening / 16 * cosSqAlpha * (4 + flattening * (4 - 3 * cosSqAlpha))
            lambdaPrev = lambda
            lambda = longitudeDifference +
                (1 - correctionFactor) * flattening * sinAlpha *
                (
                    sigma +
                    correctionFactor * sinSigma *
                    (cos2SigmaM + correctionFactor * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM))
                )
            iterLimit -= 1
        } while abs(lambda - lambdaPrev) > 1e-12 && iterLimit > 0

        if iterLimit == 0 {
            return sphericalFallbackInverse(from: from, to: to)
        }

        let uSq = cosSqAlpha * (semiMajorAxis * semiMajorAxis - semiMinorAxis * semiMinorAxis) /
            (semiMinorAxis * semiMinorAxis)
        let ellipsoidFactor = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let correctionTerm = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))
        let deltaSigma = correctionTerm * sinSigma * (
            cos2SigmaM + correctionTerm / 4 * (
                cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
                correctionTerm / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) *
                (-3 + 4 * cos2SigmaM * cos2SigmaM)
            )
        )

        let distance = semiMinorAxis * ellipsoidFactor * (sigma - deltaSigma)
        let initialBearing = atan2(
            cosU2 * sin(lambda),
            cosU1 * sinU2 - sinU1 * cosU2 * cos(lambda)
        )

        return InverseResult(distanceMeters: distance, initialBearingRad: initialBearing)
    }

    private static func direct(
        origin: GeoPointProtocol,
        initialBearingRad: Double,
        distanceMeters: Double
    ) -> (Double, Double) {
        let lat1 = deg2rad(origin.latitude)
        let lon1 = deg2rad(origin.longitude)
        let sinAlpha1 = sin(initialBearingRad)
        let cosAlpha1 = cos(initialBearingRad)

        let tanU1 = (1 - flattening) * tan(lat1)
        let cosU1 = 1 / sqrt(1 + tanU1 * tanU1)
        let sinU1 = tanU1 * cosU1
        let sigma1 = atan2(tanU1, cosAlpha1)
        let sinAlpha = cosU1 * sinAlpha1
        let cosSqAlpha = 1 - sinAlpha * sinAlpha
        let uSq = cosSqAlpha * (semiMajorAxis * semiMajorAxis - semiMinorAxis * semiMinorAxis) /
            (semiMinorAxis * semiMinorAxis)
        let ellipsoidFactor = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let correctionTerm = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))

        var sigma = distanceMeters / (semiMinorAxis * ellipsoidFactor)
        var sigmaPrev = 0.0
        var cos2SigmaM = 0.0
        var sinSigma = 0.0
        var cosSigma = 0.0

        // Android's reference loops until convergence with no iteration cap; a
        // generous cap keeps this safe without changing the converged result.
        var iterLimit = 1000
        repeat {
            cos2SigmaM = cos(2 * sigma1 + sigma)
            sinSigma = sin(sigma)
            cosSigma = cos(sigma)
            let deltaSigma = correctionTerm * sinSigma * (
                cos2SigmaM + correctionTerm / 4 * (
                    cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
                    correctionTerm / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) *
                    (-3 + 4 * cos2SigmaM * cos2SigmaM)
                )
            )
            sigmaPrev = sigma
            sigma = distanceMeters / (semiMinorAxis * ellipsoidFactor) + deltaSigma
            iterLimit -= 1
        } while abs(sigma - sigmaPrev) > 1e-12 && iterLimit > 0

        let tmp = sinU1 * sinSigma - cosU1 * cosSigma * cosAlpha1
        let lat2 = atan2(
            sinU1 * cosSigma + cosU1 * sinSigma * cosAlpha1,
            (1 - flattening) * sqrt(sinAlpha * sinAlpha + tmp * tmp)
        )
        let lambda = atan2(
            sinSigma * sinAlpha1,
            cosU1 * cosSigma - sinU1 * sinSigma * cosAlpha1
        )
        let correctionFactor = flattening / 16 * cosSqAlpha * (4 + flattening * (4 - 3 * cosSqAlpha))
        let longitudeDifference = lambda - (1 - correctionFactor) * flattening * sinAlpha *
            (
                sigma +
                correctionFactor * sinSigma *
                (cos2SigmaM + correctionFactor * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM))
            )
        let lon2 = lon1 + longitudeDifference

        return (rad2deg(lat2), normalizeLng(rad2deg(lon2)))
    }

    private static func sphericalFallbackInverse(
        from: GeoPointProtocol,
        to: GeoPointProtocol
    ) -> InverseResult {
        let lat1 = deg2rad(from.latitude)
        let lat2 = deg2rad(to.latitude)
        let deltaLat = deg2rad(to.latitude - from.latitude)
        let deltaLng = deg2rad(to.longitude - from.longitude)
        let a = sin(deltaLat / 2) * sin(deltaLat / 2) +
            cos(lat1) * cos(lat2) * sin(deltaLng / 2) * sin(deltaLng / 2)
        let centralAngle = 2 * atan2(sqrt(a), sqrt(1 - a))
        let y = sin(deltaLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLng)
        return InverseResult(
            distanceMeters: semiMajorAxis * centralAngle,
            initialBearingRad: atan2(y, x)
        )
    }

    private static func normalizeLng(_ lng: Double) -> Double {
        (((lng + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)) - 180.0
    }

    private static func deg2rad(_ degrees: Double) -> Double { degrees * .pi / 180.0 }
    private static func rad2deg(_ radians: Double) -> Double { radians * 180.0 / .pi }
}
