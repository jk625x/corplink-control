cask "corplink-control" do
  version "1.5.1"
  sha256 "f6037da299055f0157502df76414dee292532bee91069809050e2899e5360e44"

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
