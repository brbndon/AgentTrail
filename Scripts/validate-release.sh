#!/bin/zsh
# Validate a final Release artifact after Developer ID signing, notarization,
# and stapling. Do not invoke from an Xcode build phase (sandboxed pre-sign
# phases cannot see notarization tickets).
#
# Prerequisites:
#   - AGENTTRAIL_DEVELOPMENT_TEAM set for the archive/Release build
#   - codesign with "Developer ID Application"
#   - notarytool submit + stapler staple completed
#
# Usage (CI/archive only, post-staple):
#   ./Scripts/validate-release.sh /path/to/AgentTrail.app
set -euo pipefail

app_path="${1:-}"
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  print -u2 "Usage: validate-release.sh /path/to/AgentTrail.app"
  exit 2
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"
xcrun stapler validate "$app_path"
print "Release validation passed for $app_path"
