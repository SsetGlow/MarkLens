cask "marklens" do
  version "0.1.3"
  sha256 "2cd1afa79fd84f4d1b275a5a8989a3c04fa7e88090b8f157a87599aceaa3f9b0"

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
