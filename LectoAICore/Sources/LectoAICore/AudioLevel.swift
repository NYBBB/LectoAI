import Foundation

/// 试音只计算有界样本的电平，不将静音等同于授权失败。
public struct AudioLevel: Sendable, Equatable {
    public let decibels: Double
    public var normalized: Double { min(1, max(0, (decibels + 60) / 60)) }

    public init(samples: [Float]) {
        let finite = samples.filter { $0.isFinite }
        guard !finite.isEmpty else { decibels = -120; return }
        let power = finite.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(finite.count)
        decibels = max(-120, min(0, 10 * log10(max(power, 1e-12))))
    }
}
