# The release workflow rewrites `version` and `sha256` on every tag.
cask "termora" do
  version "0.2.6"
  sha256 "a6708f7b7052c6a435cad53028b6420b248c10d52268d26aacbe4fdc04e966d3"

  url "https://github.com/fballiano/termora/releases/download/v#{version}/Termora-#{version}.zip"
  name "Termora"
  desc "SSH connection manager on the Ghostty terminal engine"
  homepage "https://github.com/fballiano/termora"

  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Termora.app"

  caveats <<~EOS
    Termora is signed ad hoc, not with an Apple Developer ID, so macOS
    blocks the first launch. Open System Settings -> Privacy & Security
    and select Open Anyway, or clear the mark from a terminal:

      xattr -dr com.apple.quarantine /Applications/Termora.app
  EOS
end
