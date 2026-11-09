#!/usr/bin/env ruby
# Generates tvos/NFSMW.xcodeproj (gem xcodeproj): the Apple TV app around out/<sdk>/libnfsmw.a.
#   BUNDLE_ID=com.you.nfsmw TEAM=ABCDE12345 GAME="/path/to/game folder" ruby tvos/make_project.rb
# (tvos/tv.sh project does this, reading tvos/local.env.) Build phases, in order:
#   1. tvos/build.sh            the game and the runtime as a static library, for the SDK being built
#   2. Sources, Frameworks       main.m, linked with the library (-force_load: hooks are strong overrides) and FFmpeg
#   3. Resources                 the asset catalog (icons: out/tvos-assets, made by tvos/tv.sh)
#   4. tvos/stage_game.sh        the player's game folder into the app as Game/ (APFS clones)
require 'fileutils'
require 'xcodeproj'

dir = File.expand_path(__dir__)
root = File.expand_path('..', dir)
path = File.join(dir, 'NFSMW.xcodeproj')
bundle_id = ENV['BUNDLE_ID'] or abort 'make_project.rb: set BUNDLE_ID (your own, e.g. com.yourname.nfsmw)'
team = ENV['TEAM'] or abort 'make_project.rb: set TEAM (your Apple developer team ID)'
game = File.expand_path(ENV['GAME'] || File.join(root, 'NFS Most Wanted'))
abort "make_project.rb: no speed.exe in #{game} (set GAME)" unless File.exist?(File.join(game, 'speed.exe'))
minos = ENV['MINOS'] || '17.0'

FileUtils.rm_rf(path)
project = Xcodeproj::Project.new(path)
target = project.new_target(:application, 'NFSMW', :tvos, minos)

app = project.main_group.new_group('app', 'app')
target.add_file_references([app.new_file('main.m')])
app.new_file('Info.plist')
app.new_file('NFSMW.entitlements')
assets = project.main_group.new_file(File.join(root, 'out', 'tvos-assets', 'Assets.xcassets'))
target.resources_build_phase.add_file_reference(assets)

lib = target.new_shell_script_build_phase('Build libnfsmw.a (tvos/build.sh)')
lib.shell_script = %q(SDK="$PLATFORM_NAME" exec "$SRCROOT/build.sh")
lib.always_out_of_date = '1'
target.build_phases.delete(lib)
target.build_phases.insert(0, lib)

stage = target.new_shell_script_build_phase('Copy the game folder (tvos/stage_game.sh)')
stage.shell_script = %q(exec "$SRCROOT/stage_game.sh")
stage.always_out_of_date = '1'

%w[UIKit Foundation Metal QuartzCore GameController CoreHaptics CoreGraphics CoreText AudioToolbox AVFoundation ImageIO
   VideoToolbox CoreVideo CoreMedia Security SystemConfiguration UniformTypeIdentifiers].each { |f| target.add_system_framework(f) }

ff = '$(SRCROOT)/../third_party/ffmpeg-$(PLATFORM_NAME)/lib'
target.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
  s['PRODUCT_NAME'] = 'NFSMW'
  s['INFOPLIST_FILE'] = 'app/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['DEVELOPMENT_TEAM'] = team
  s['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  s['TARGETED_DEVICE_FAMILY'] = '3'
  s['TVOS_DEPLOYMENT_TARGET'] = minos
  s['SDKROOT'] = 'appletvos'
  s['SUPPORTED_PLATFORMS'] = 'appletvos appletvsimulator'
  s['ARCHS'] = 'arm64'
  s['ONLY_ACTIVE_ARCH'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['ENABLE_BITCODE'] = 'NO'
  s['DEAD_CODE_STRIPPING'] = 'NO'          # translated functions are reached through the guest-address table
  s['ENABLE_DEBUG_DYLIB'] = 'NO'           # one executable, no SwiftUI preview split
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'App Icon & Top Shelf Image'
  s['MARKETING_VERSION'] = ENV['VERSION'] || '1.0'
  s['CURRENT_PROJECT_VERSION'] = ENV['BUILD'] || '1'
  s['NFSMW_GAME'] = game
  s['CODE_SIGN_ENTITLEMENTS'] = 'app/NFSMW.entitlements'
  s['OTHER_LDFLAGS'] = ['-Wl,-force_load,$(SRCROOT)/../out/$(PLATFORM_NAME)/libnfsmw.a',
                        "#{ff}/libavformat.a", "#{ff}/libavcodec.a", "#{ff}/libswscale.a", "#{ff}/libswresample.a",
                        "#{ff}/libavutil.a", '-lc++', '-lz', '-weak_framework', 'MetalFX']
end
project.save
project.recreate_user_schemes
puts "make_project.rb: wrote #{path} (#{bundle_id}, team #{team}, game #{game})"
