#!/usr/bin/env bash
# Prints the Homebrew cask for a release:  scripts/release/cask.sh <version> <zip>
# The tap (vars.HOMEBREW_TAP, e.g. usehomemade/homebrew-tap) gets it as
# Casks/needs-you.rb; users run `brew install --cask usehomemade/tap/needs-you`.
set -euo pipefail
version=$1 zip=$2
repo=${RELEASES_REPO:-usehomemade/needs-you}
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
cat <<RUBY
cask "needs-you" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/NeedsYou-#{version}.zip"
  name "Needs You"
  desc "Lets coding agents ask you out loud and hear your spoken answer"
  homepage "https://github.com/$repo"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Needs You.app"
  binary "#{appdir}/Needs You.app/Contents/Helpers/needs-you"

  zap trash: [
    "~/Library/Application Support/FluidAudio",
    "~/Library/Application Support/Needs You",
    "~/Library/Caches/dev.homemade.needs-you",
    "~/Library/HTTPStorages/dev.homemade.needs-you",
    "~/Library/Preferences/dev.homemade.needs-you.plist",
  ]
end
RUBY
