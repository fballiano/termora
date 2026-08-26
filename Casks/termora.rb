# The release workflow rewrites `version` and `sha256` on every tag.
cask "termora" do
  version "0.1.0"
  sha256 "ee1aa328b2680cae1aba8a5ee9a3a85e97d7692be7ef1b2cc1ae486e49389937"

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
