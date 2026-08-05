public protocol MapDesignTypeProtocol {
    associatedtype Identifier

    var id: Identifier { get }
    var attributionRules: [AttributionRule] { get }

    func getValue() -> Identifier
}

public extension MapDesignTypeProtocol {
    var attributionRules: [AttributionRule] { [] }
}
