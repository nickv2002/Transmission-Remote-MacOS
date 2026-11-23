cask "transmission-remote" do
  version "@VERSION@"
  sha256 "@SHA256_APP@"

  url "https://github.com/nickv2002/Transmission-Remote-MacOS/releases/download/v#{version}/Transmission.Remote-#{version}.zip"
  name "Transmission Remote"
  desc "Native remote control for Transmission BitTorrent servers"
  homepage "https://github.com/nickv2002/Transmission-Remote-MacOS"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Transmission Remote.app"

  zap trash: [
    "~/Library/Caches/com.nickvance.transmission-remote-mac",
    "~/Library/HTTPStorages/com.nickvance.transmission-remote-mac",
    "~/Library/Preferences/com.nickvance.transmission-remote-mac.plist",
    "~/Library/Saved Application State/com.nickvance.transmission-remote-mac.savedState",
  ]
end
