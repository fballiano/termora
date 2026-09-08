# The release workflow rewrites `version` and `sha256` on every tag.
cask "termora" do
  version "0.4.7"
  sha256 "4451f21828ea9c370c6065da5d9719a5836ae6033c62cadb7089fa7cea372004"

  url "https://github.com/fballiano/termora/releases/download/v#{version}/Termora-#{version}.zip"
  name "Termora"
  desc "SSH connection manager on the Ghostty terminal engine"
  homepage "https://github.com/fballiano/termora"

  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Termora.app"
  binary "#{appdir}/Termora.app/Contents/MacOS/termora-cli", target: "termora"

  caveats <<~EOS
    Termora is signed ad hoc, not with an Apple Developer ID, so macOS
    blocks the first launch. Open System Settings -> Privacy & Security
    and select Open Anyway, or clear the mark from a terminal:

      xattr -dr com.apple.quarantine /Applications/Termora.app
  EOS
end
