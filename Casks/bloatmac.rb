cask "bloatmac" do
  version "1.1.1"
  sha256 "3ac5795eb3424dd132094755c94478678c2edcdfbd6b2d6e89e946e2ff71fcc5"

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

  caveats <<~EOS
    BloatMac is ad-hoc signed and is not Apple-notarized. On first launch, try
    opening BloatMac, then go to System Settings > Privacy & Security, scroll to
    Security, and click Open Anyway. Authenticate and confirm Open once.
  EOS

  app "BloatMac.app"

  zap trash: [
    "~/Library/Application Support/BloatMac",
    "~/Library/Preferences/akhilgautam123.bloatmac.plist",
    "~/Library/Saved Application State/akhilgautam123.bloatmac.savedState",
  ]
end
