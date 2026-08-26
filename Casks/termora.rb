# The release workflow rewrites `version` and `sha256` on every tag.
cask "termora" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/fballiano/termora/releases/download/v#{version}/Termora-#{version}.zip"
  name "Termora"
  desc "SSH connection manager on the Ghostty terminal engine"
  homepage "https://github.com/fballiano/termora"

  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Termora.app"

  caveats <<~EOS
    Termora is ad-hoc signed, so macOS quarantines the download.
    Install with the flag that skips the quarantine:

      brew install --cask --no-quarantine termora

    Or clear it after the install:

      xattr -dr com.apple.quarantine /Applications/Termora.app
  EOS
end
