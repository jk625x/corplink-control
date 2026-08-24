cask "corplink-control" do
  version "1.5.2"
  sha256 "0f8439ad0296d63cbd74db6481d2f59c465a1efed93e29066b00a0b13698a0d4"

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
