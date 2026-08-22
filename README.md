# 飞连控制

原生 macOS App，用于逐项查看、启动和停止飞连的连接、防护、网络监控、MDM、
网络代理、应用管控和客户端任务。支持 Apple Silicon 和 Intel Mac。

App 同时提供标准主窗口和可选菜单栏入口。主控制页只保留整套状态、服务数量以及开始、停止、刷新三个按钮；
逐项 PID、属性和恢复条件放在组件与信息页。可以设置登录时启动控制 App，以及是否显示菜单栏图标。

## 两种停止方式

“停止连接服务”会干净停止 `com.volcengine.corplink.service`：先通过飞连自带 CLI 主动断开
VPN/SWG，再从 launchd system domain 卸载主服务，确认无主进程残留并观察 5 秒防止复活，最后恢复
plist 原有的不可变属性。

“停止整套”会先保存停止前运行快照，再逐项卸载 8 个已知 launchd 任务、清理对应孤立进程、恢复
`schg/uchg`，并观察 5 秒。只有任务、进程和已知活跃 System Extension 都不存在时才显示“整套已干净停止”。
它不会删除飞连文件，因此不是卸载。

“恢复停止前状态”只恢复快照中原先运行的组件，不会擅自启用组织策略已禁用的 MDM。需要特别注意：
`com.corplink.networkmonitor` 设置了 `LaunchOnlyOnce=true`，停止后必须重启 Mac 才能可靠恢复；界面会明确
显示“需要重启”，不会伪装成可以热启动。

完整的原理、组件清单、验证标准和已知边界见
[停止语义、原理与验证](docs/STOPPING.md)。也可以运行只读审计：

```bash
./scripts/audit-stop.sh
```

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
