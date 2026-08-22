cask "corplink-control" do
  version "1.5.0"
  sha256 "88fcb620d6e56094fc37fe17d17b719c145055945a8015a4d1401ca06bbf45a0"

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
