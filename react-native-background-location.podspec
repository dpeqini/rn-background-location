require "json"
Pod::Spec.new do |s|
  s.name = "react-native-background-location"
  s.version = "0.1.0"
  s.summary = "Native-first adaptive background location tracking for React Native"
  s.homepage = "https://example.invalid"
  s.license = { :type => "MIT" }
  s.author = { "Greinchville" => "dev@example.invalid" }
  s.platforms = { :ios => "15.0" }
  s.source = { :git => "https://example.invalid/repo.git", :tag => s.version.to_s }
  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.frameworks = "CoreLocation", "CoreMotion"
  s.libraries = "sqlite3"
  s.dependency "React-Core"
  install_modules_dependencies(s)
end
