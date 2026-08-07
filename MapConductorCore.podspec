Pod::Spec.new do |s|
  s.name = "MapConductorCore"
  s.version = "1.2.0"
  s.summary = "MapConductor's provider-agnostic core types and protocols."
  s.license = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author = "MapConductor"
  s.homepage = "https://github.com/MapConductor/ios-sdk-core"
  s.source = { :path => __dir__ }
  s.platform = :ios, "15.1"
  s.swift_version = "5.9"
  s.source_files = "Sources/MapConductorCore/**/*.swift"
end
