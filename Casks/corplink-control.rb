cask "corplink-control" do
  version "1.0.0"
  sha256 "2496161bb79417ff0a7315724bd5235295a1cf2e080f8335e32d4aa39aa90fd3"

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
