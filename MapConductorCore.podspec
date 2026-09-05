Pod::Spec.new do |s|
  s.name = "MapConductorCore"
  s.version = "1.3.1"
  s.summary = "MapConductor's provider-agnostic core types and protocols."
  s.license = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author = "MapConductor"
  s.homepage = "https://github.com/MapConductor/ios-sdk-core"
  s.source = { :git => "https://github.com/MapConductor/ios-sdk-core.git", :tag => s.version.to_s }
  s.platform = :ios, "15.1"
  s.swift_version = "5.9"
  s.source_files = "Sources/MapConductorCore/**/*.swift", "Sources/CTilePng/**/*.{c,h}"
  s.public_header_files = "Sources/CTilePng/include/*.h"
  # The Rust PNG encoder. Marker tiles are rasterised in-process and the
  # platform encoder is several times slower; MarkerTileRenderer falls back to
  # it if this is missing, so the pod stays usable either way.
  s.vendored_frameworks = "TilePng.xcframework"
end
