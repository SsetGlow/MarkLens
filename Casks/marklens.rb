cask "marklens" do
  version "0.1.2"
  sha256 "06ecad84852990689a4dae3f08a6f80a9a847b2bf89734e5c5519ef8ce27171b"

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
