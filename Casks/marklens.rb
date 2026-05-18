cask "marklens" do
  version "0.1.1"
  sha256 "f7aea4cf4227a8a008c2552cab9af6ef1ad618536fa2f7f60797cd20f9ee4e6f"

  url "https://github.com/SsetGlow/MarkLens/releases/download/v#{version}/MarkLens-#{version}-arm64.dmg"
  name "MarkLens"
  desc "Native same-canvas Markdown editor for macOS"
  homepage "https://github.com/SsetGlow/MarkLens"

  app "MarkLens.app"

  zap trash: [
    "~/Library/Preferences/com.ssetglow.marklens.plist",
    "~/Library/Saved Application State/com.ssetglow.marklens.savedState",
  ]
end
