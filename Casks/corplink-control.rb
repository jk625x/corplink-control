cask "corplink-control" do
  version "1.6.0"
  sha256 "b24542bf3fa626ac0a2b38c14f344b53ace086b9e5cf6f16ba3fe72c2b650cf6"

  url "https://github.com/jk625x/corplink-control/releases/download/v#{version}/CorplinkControl-#{version}.zip"
  name "Corplink Control"
  desc "Menu bar controller for the Corplink system service"
  homepage "https://github.com/jk625x/corplink-control"

  depends_on macos: :ventura

  app "Corplink Control.app"

  caveats <<~EOS
    This build is not notarized with a Developer ID. If macOS blocks the first launch,
    open System Settings > Privacy & Security and choose Open Anyway.
  EOS
end
