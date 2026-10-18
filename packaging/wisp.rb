# Homebrew cask. Publish in your own tap first (github.com/gaurang404/homebrew-tap → `brew install --cask gaurang404/tap/wisp`),
# submit to homebrew/cask once the repo meets its notability requirements.
# Update `version` and `sha256` (from SHA256SUMS.txt in the release) for each release.
cask "wisp" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_Wisp-#{version}.dmg"

  url "https://github.com/gaurang404/wisp/releases/download/v#{version}/Wisp-#{version}.dmg"
  name "Wisp"
  desc "Native API client with Keychain credentials, GraphQL and OpenAPI import"
  homepage "https://wisp.build/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Wisp.app"

  zap trash: [
    "~/Library/Application Support/Wisp",
    "~/Library/Preferences/build.wisp.app.plist",
    "~/Library/Saved Application State/build.wisp.app.savedState",
  ]
end
