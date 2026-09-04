platform :ios, '16.0'

require 'fileutils'

project 'DJIVLNiOS.xcodeproj'

target 'DJIVLNiOS' do
  pod 'DJI-SDK-iOS', '4.16.2'
  pod 'DJIWidget', '1.6.8'

  target 'DJIVLNiOSTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
    end
  end

  # DJI iOS SDK 4.16.2 and DJIWidget's bundled FFmpeg predate Apple's
  # PrivacyInfo.xcprivacy requirement. Keep the declarations in source control
  # and inject them before CocoaPods embeds and signs the vendored frameworks.
  privacy_manifests = {
    'PrivacyManifests/DJISDK-PrivacyInfo.xcprivacy' =>
      'Pods/DJI-SDK-iOS/iOS_Mobile_SDK/DJISDK.framework/PrivacyInfo.xcprivacy',
    'PrivacyManifests/FFmpeg-PrivacyInfo.xcprivacy' =>
      'Pods/DJIWidget/FFmpeg/FFmpeg.framework/PrivacyInfo.xcprivacy'
  }
  privacy_manifests.each do |source, destination|
    source_path = File.join(__dir__, source)
    destination_path = File.join(__dir__, destination)
    raise "Missing privacy manifest source: #{source_path}" unless File.file?(source_path)
    raise "Missing vendored framework: #{File.dirname(destination_path)}" unless File.directory?(File.dirname(destination_path))

    FileUtils.cp(source_path, destination_path)
  end
end
