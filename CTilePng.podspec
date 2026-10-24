Pod::Spec.new do |s|
  s.name = "CTilePng"
  s.version = "1.3.1"
  s.summary = "The C shim MapConductorCore's Rust PNG encoder is reached through."
  s.license = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author = "MapConductor"
  s.homepage = "https://github.com/MapConductor/ios-sdk-core"
  s.source = { :git => "https://github.com/MapConductor/ios-sdk-core.git", :tag => s.version.to_s }
  s.platform = :ios, "15.1"
  # Its own pod, not source files inside MapConductorCore.
  #
  # `TilePngEncoder.swift` says `import CTilePng`, which needs CTilePng to be
  # a module. Compiled *into* MapConductorCore the C has no module of its own
  # and that import does not resolve -- Swift Package Manager gives it one
  # because it is a separate target there, and CocoaPods only does the same if
  # it is a separate pod. Without this the pod builds everywhere except where
  # it matters: React Native, which consumes the source pod.
  s.source_files = "Sources/CTilePng/**/*.{c,h}"
  s.public_header_files = "Sources/CTilePng/include/*.h"
end
