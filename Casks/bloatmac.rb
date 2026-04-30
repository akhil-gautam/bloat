cask "bloatmac" do
  version "0.1.1"
  sha256 "ac6e622ad23337fbed7c17d2d1b0df1ebf85785c0ceceecfa3ebe5e991892f28"

  url "https://github.com/akhil-gautam/bloat/releases/download/bloatmac-v#{version}/BloatMac-v#{version}-macos.dmg"
  name "BloatMac"
  desc "Native macOS companion app for the bloat disk-analyzer CLI"
  homepage "https://github.com/akhil-gautam/bloat"

  livecheck do
    url :url
    strategy :github_latest do |json|
      tag = json["tag_name"]
      next unless tag&.start_with?("bloatmac-v")
      tag.sub("bloatmac-v", "")
    end
  end

  depends_on macos: ">= :tahoe"

  app "BloatMac.app"

  # The release is ad-hoc signed (not Developer-ID notarized). Strip quarantine
  # so Gatekeeper allows launch after install.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/BloatMac.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/BloatMac",
    "~/Library/Preferences/akhilgautam123.bloatmac.plist",
    "~/Library/Saved Application State/akhilgautam123.bloatmac.savedState",
  ]
end
