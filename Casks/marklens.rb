cask "marklens" do
  version "0.1.0"
  sha256 "18432461829ced27b4862d7450fa5037502a79bbcc8e00a33cce2ff32796adc6"

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
