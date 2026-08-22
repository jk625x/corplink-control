cask "corplink-control" do
  version "1.3.0"
  sha256 "60e833b9134b12960e9e4cf57b12bbc4773a64ffcde5137c36200c31fff51060"

  url "https://github.com/jk625x/corplink-control/releases/download/v#{version}/CorplinkControl-#{version}.zip"
  name "飞连控制"
  desc "Menu bar controller for the Corplink system service"
  homepage "https://github.com/jk625x/corplink-control"

  depends_on macos: :ventura

  app "飞连控制.app"

  caveats <<~EOS
    此版本未使用 Developer ID 公证。macOS 首次拦截启动时，请在
    “系统设置 → 隐私与安全性”中选择“仍要打开”。
  EOS
end
