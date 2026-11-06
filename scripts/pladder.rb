cask "pladder" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/dinooo13/pladder/releases/download/v#{version}/Pladder.dmg"
  name "Pladder"
  desc "Push-to-talk dictation with on-device speech recognition"
  homepage "https://dinooo13.github.io/pladder/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Pladder.app"

  uninstall quit: "de.dinooo13.pladder"

  zap trash: [
        "~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3",
        "~/Library/Application Support/FluidAudio/Models/parakeet-ultra",
        "~/Library/Application Support/Pladder",
        "~/Library/Caches/de.dinooo13.pladder",
        "~/Library/HTTPStorages/de.dinooo13.pladder",
        "~/Library/Preferences/de.dinooo13.pladder.plist",
      ],
      rmdir: "~/Library/Application Support/FluidAudio"
end
