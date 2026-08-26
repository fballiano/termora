# The release workflow rewrites `version` and `sha256` on every tag.
cask "termora" do
  version "0.2.2"
  sha256 "1ae461bb85bd7daff189366ade95e9bf4f77036136270ceeb193639704efe85a"

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
