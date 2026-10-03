#!/bin/sh
# Xcode Cloud: Xcode 26 ships the Metal compiler as a separate component that build images don't
# always include, and the app compiles a SwiftUI shader (ClickDropDevelop.metal).
set -e
xcodebuild -downloadComponent MetalToolchain
