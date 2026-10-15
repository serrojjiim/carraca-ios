platform :ios, '16.0'
use_frameworks!

target 'Carraca' do
  # Motor VLC: reproduce TS (directo) y MKV/AVI (pelis y series), que el
  # reproductor nativo de iOS no soporta.
  pod 'MobileVLCKit', '~> 3.6.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
  end
end
