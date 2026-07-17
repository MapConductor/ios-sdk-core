import Foundation
import SwiftUI
import UIKit

public struct MapAttributionOverlay: View {
    private let attributions: [String]

    public init(
        designRules: [AttributionRule],
        rasterLayers: [RasterLayer],
        camera: MapCameraPositionProtocol
    ) {
        self.attributions = resolveMapAttributions(
            designRules: designRules,
            rasterLayers: rasterLayers,
            camera: camera
        )
    }

    public var body: some View {
        if !attributions.isEmpty {
            VStack {
                Spacer()
                HStack {
                    Spacer(minLength: 8)
                    Text(Self.makeAttributedString(from: attributions.joined(separator: " | ")))
                        .font(.system(size: 10))
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.85))
                }
                .padding(.trailing, 4)
                .padding(.bottom, 24)
            }
        }
    }

    private static func makeAttributedString(from html: String) -> AttributedString {
        guard let data = html.data(using: .utf8),
              let value = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              )
        else {
            return AttributedString(html)
        }
        return AttributedString(value)
    }
}
