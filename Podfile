platform :ios, '17.0'

target 'Beacon' do
  use_frameworks!

  pod 'LibSignalClient',
      git: 'https://github.com/signalapp/libsignal.git',
      tag: 'v0.96.4'

  # FaceTime v1 media (P1): stasel/WebRTC prebuilt libwebrtc, EXACT-version
  # pinned (spec checksum recorded in Podfile.lock, same posture as the
  # LibSignalClient tag+checksum pin). Media only — signaling stays on the
  # existing sealed channel (kinds 8-10).
  pod 'WebRTC-lib', '= 149.0.0'

  target 'BeaconTests' do
    inherit! :search_paths
  end
end

ENV['LIBSIGNAL_FFI_PREBUILD_CHECKSUM'] = 'afac333d0ee6dd86786316bb8346d8dd61ca153afb5080362a35553a701efa4f'

post_install do |installer|
  installer.pods_project.targets.each do |target|
    next unless %w[Pods-Beacon Pods-BeaconTests].include?(target.name)
    target.build_configurations.each do |config|
      ffi = '"${PODS_ROOT}/LibSignalClient/swift/Sources/SignalFfi"'
      config.build_settings['SWIFT_INCLUDE_PATHS'] = "$(inherited) #{ffi}"
      config.build_settings['HEADER_SEARCH_PATHS'] = "$(inherited) #{ffi}"
    end
  end
end
