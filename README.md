# 飞连控制

原生 macOS 菜单栏 App，用于查看、启动和停止
`com.volcengine.corplink.service`。支持 Apple Silicon 和 Intel Mac。

App 同时提供标准主窗口和可选菜单栏入口。主窗口包含控制、信息、设置和关于页面；
可以设置登录时启动控制 App，以及是否显示菜单栏图标。

## 安装

仓库同时包含源码和 Homebrew Cask，不需要单独的 `homebrew-tap` 仓库：

```bash
brew tap jk625x/corplink-control https://github.com/jk625x/corplink-control
brew trust --cask jk625x/corplink-control/corplink-control
brew install --cask jk625x/corplink-control/corplink-control
```

Homebrew 将第三方 Cask 仓库统称为 tap；这里的 tap 就是当前个人项目仓库，
不会创建另一个仓库。Homebrew 6 默认不加载未经信任的第三方 Cask，因此安装者需要明确执行一次
`brew trust`；上面的命令只信任当前 Cask，而不是整个仓库。

## 构建

```bash
./build-app.sh
```

构建产物位于 `dist/飞连控制.app`。直接打开后，菜单栏会出现盾牌图标。
查看状态不需要权限；启动或停止服务时，macOS 会弹出管理员授权窗口。

当前版本使用 AppleScript 的管理员授权机制，适合本机自用。由于还没有 Developer ID
签名和公证，其他人的 Mac 首次打开时可能需要在“系统设置 → 隐私与安全性”中确认。
正式分发时建议进一步使用 Developer ID 签名、公证，并将 helper 升级为
ServiceManagement privileged helper。
