#!/bin/bash
#
# Xcode Cloud post-clone hook. Optional — include it only if the project uses SwiftPM plugins or
# macros, which Xcode Cloud otherwise stops to ask about interactively (and so hangs).
#
# Note the misspelled key: that is Apple's spelling, not a typo here.
set -euo pipefail

defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
