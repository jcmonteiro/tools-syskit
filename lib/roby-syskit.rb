# Plugin file for Roby
require 'syskit'
Roby.app.register_app_extension 'syskit', Syskit::RobyApp::Plugin
Syskit::RobyApp::Plugin.enable

