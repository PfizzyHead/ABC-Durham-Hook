// LinearRegression.swift
//
// Ordinary-least-squares slope of a sampled signal against time, implemented
// with Accelerate's vDSP so the per-axis velocity fit is vectorized.

import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

enum LinearRegression {

    /// Slope d(value)/d(time) of `values` regressed on `times`.
    ///
    /// Fitting a line over a short window (rather than differencing two frames)
    /// rejects per-frame detection jitter: the slope is the maximum-likelihood
    /// velocity under Gaussian position noise. Returns 0 for degenerate input.
    static func slope(times: [Double], values: [Double]) -> Double {
        precondition(times.count == values.count, "times/values length mismatch")
        let n = times.count
        guard n >= 2 else { return 0 }

        #if canImport(Accelerate)
        var meanT = 0.0, meanV = 0.0
        vDSP_meanvD(times, 1, &meanT, vDSP_Length(n))
        vDSP_meanvD(values, 1, &meanV, vDSP_Length(n))

        // Center both signals on their means.
        var negMeanT = -meanT
        var negMeanV = -meanV
        var dt = [Double](repeating: 0, count: n)
        var dv = [Double](repeating: 0, count: n)
        vDSP_vsaddD(times, 1, &negMeanT, &dt, 1, vDSP_Length(n))
        vDSP_vsaddD(values, 1, &negMeanV, &dv, 1, vDSP_Length(n))

        // slope = (dt · dv) / (dt · dt)
        var numerator = 0.0
        var denominator = 0.0
        vDSP_dotprD(dt, 1, dv, 1, &numerator, vDSP_Length(n))
        vDSP_dotprD(dt, 1, dt, 1, &denominator, vDSP_Length(n))
        guard denominator > 1e-12 else { return 0 }
        return numerator / denominator
        #else
        // Portable fallback for non-Apple platforms (keeps the package buildable).
        let meanT = times.reduce(0, +) / Double(n)
        let meanV = values.reduce(0, +) / Double(n)
        var numerator = 0.0
        var denominator = 0.0
        for i in 0..<n {
            let d = times[i] - meanT
            numerator += d * (values[i] - meanV)
            denominator += d * d
        }
        guard denominator > 1e-12 else { return 0 }
        return numerator / denominator
        #endif
    }
}
