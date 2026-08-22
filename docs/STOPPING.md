# 停止语义、原理与验证

## 先说结论

“停止”表示**干净停止飞连的连接主服务**，不表示卸载飞连，也不表示关闭飞连的全部安全与合规组件。

在 2026-08-23 对 macOS 26.6.2、CorpLink 3.3.15 的实机审计中，飞连至少安装了以下独立任务：

| launchd 标签 | 作用或可执行文件 | 本工具的“停止”是否处理 |
| --- | --- | --- |
| `com.volcengine.corplink.service` | 连接主服务 `corplink-service` | 是 |
| `com.volcengine.corplink.systemextension` | firewall、EDR、EDLP、AV、设备管控等 | 否 |
| `com.corplink.networkmonitor` | `NetworkMonitor` | 否 |
| `com.corplink.data_forwarder` | 策略数据转发 | 否 |
| `com.corplink.mdm.policy` | MDM 策略 | 否 |
| `com.volcengine.corplink.agent` | `CorplinkNe` 网络扩展代理 | 否 |
| `com.corplink.appblocker` | 应用管控 | 否 |
| `CorpLink` | 用户登录项 | 否 |

因此，界面会分别展示“连接服务”和“独立后台组件”，不会把主服务停止误报成“整个飞连完全退出”。

## 为什么不能把所有进程直接杀掉

多个飞连任务设置了 `KeepAlive=true`。根据 macOS 的 `launchd.plist(5)` 系统手册，`KeepAlive`
会要求 launchd 持续维持进程；只执行 `kill` 或 `launchctl stop`，进程会被再次拉起。

`com.corplink.networkmonitor` 还设置了 `LaunchOnlyOnce=true`。系统手册将它定义为：任务不能在不完整重启
机器的情况下安全地再次运行。因此，本工具不会为了追求“进程列表看起来为空”而停止这类组件，否则按钮上的
“启动”无法保证恢复飞连原有的 EDR、AV、MDM、网络监控等能力。

需要彻底移除全部组件时，应使用组织管理员认可的飞连卸载流程。飞连 3.3.15 自带的
`/usr/local/corplink/uninstall.sh` 也采用了卸载 Network Extension、停止守护任务并删除组件的流程；
它不是普通的可逆开关。

## 干净停止连接服务的步骤

1. 使用飞连自带的 `corplink-cli vpn disconnect` 请求 VPN 主动断开。
2. 使用 `corplink-cli swg disconnect` 请求 Secure Web Gateway 主动断开。
3. 读取主服务 plist 原有的 `schg/uchg` 属性，只对这一个文件临时移除实际存在的属性。
4. 使用 `launchctl bootout system/com.volcengine.corplink.service` 从 system domain 移除任务。
   这一步与单纯杀进程不同：任务定义已不在 launchd domain 内，所以 `KeepAlive` 不会再次拉起它。
5. 仅在任务已卸载但仍有孤立主进程时，先发 `SIGTERM`，两秒后仍未退出才发 `SIGKILL`。
6. 验证 launchd job 不存在、`/usr/local/corplink/corplink-service` 精确路径的进程不存在。
7. 持续观察 5 秒；任何一次发现任务或进程重新出现，都将本次停止判为失败。
8. 恢复 plist 停止前原有的 `schg/uchg` 属性，避免因为控制操作永久降低文件保护。

启动时使用现代 `launchctl bootstrap system <plist>`；已加载时使用 `kickstart -k`，并同时验证 job 和进程。

## “已停止”的判定

连接服务只有同时满足以下条件才显示为已停止：

- `launchctl print system/com.volcengine.corplink.service` 返回“任务不存在”；
- 找不到命令行精确匹配 `/usr/local/corplink/corplink-service` 的进程；
- 停止操作后的 5 秒观察期内没有复活；
- plist 原有不可变属性已恢复。

VPN/SWG、独立后台任务、相关进程和已激活的飞连 System Extension 会作为单独诊断项显示。VPN/SWG 在主服务
已停止后可能显示“无法查询”，因为它们的本地 gRPC 服务也随主服务退出；这不应被误解为整个飞连已卸载。

可以运行只读审计：

```bash
./scripts/audit-stop.sh
```

脚本退出码：`0` 表示连接服务正在运行，`3` 表示连接服务已停止，`1` 表示 job 与进程状态不一致。

## 2026-08-23 实机闭环验证

验证环境：macOS 26.6.2、CorpLink 3.3.15、飞连控制 1.2.0。测试不是只看一次按钮状态，
而是实际执行一次“启动 → 停止”，随后再次延时检查。结果如下：

| 检查项 | 结果 |
| --- | --- |
| 启动后主任务与主进程 | 均存在，确认测试确实启动了服务 |
| 停止后 launchd job | `system/com.volcengine.corplink.service` 不存在 |
| 停止后主进程 | 无精确路径匹配的 `corplink-service` 进程 |
| 防复活观察 | 内置连续观察 5 秒通过；延时复查仍未重新出现 |
| 官方 VPN / SWG 状态 | 停止前均执行官方 disconnect；主服务退出后状态接口不可用，符合其本地服务已退出的行为 |
| plist 防护属性 | 停止前后的 `schg` 一致，临时解锁后已经恢复 |
| 飞连 System Extension | 未发现已激活的已知飞连标识 |
| DNS 与系统代理 | 停止后的完整配置哈希与测试前一致 |
| 路由 | 停止后没有 IPv4 `utun` 路由；去除 `Expire` 等动态列后的 IPv4 路由集合保持稳定；IPv6 路由哈希与测试前一致 |
| 独立后台组件 | 系统防护、网络监控、网络扩展代理、应用管控仍运行，符合本工具的明确边界 |

`netstat` 原始输出中的 `Expire` 是倒计时，直接对整段文本求哈希会自然变化。因此路由复查同时采用
“目标、网关、标志、接口”四列的规范化集合和 `utun` 路由计数，避免把动态显示字段误报为网络残留。

上述结果确认的是这台机器、这个飞连版本上的连接服务停止语义。企业策略、飞连升级或不同组织配置可能改变
组件清单，因此 App 会继续以实时状态为最终依据，不把一次测试写成对所有环境的绝对保证。

## 网络残留检查的边界

- `utun` 接口不能作为飞连专属证据：Tailscale、其他 VPN 和系统服务也会创建 `utun`。
- Finder Sync 的静态注册不代表扩展正在运行。
- 本工具检查飞连已知的 Network/System Extension 标识和相关进程，但不会删除系统 VPN 配置、路由或 DNS
  配置；这些应由前置的官方 `vpn disconnect` / `swg disconnect` 完成。
- 企业 MDM、飞连升级或管理员策略可能重新加载任务。每次操作后都应以 App 的实时状态为准。
- 组件标签和路径来自 CorpLink 3.3.15 的实机安装。版本升级后如果厂商改变组件，应重新审计。

## 依据

- 本机系统手册：`man launchctl`、`man launchd.plist`。其中 `bootout` 用于从 domain 移除服务，
  `KeepAlive` 会维持任务运行，`LaunchOnlyOnce` 表示任务不能安全地重复启动。
- [Apple：Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Apple：System extensions in macOS](https://support.apple.com/guide/deployment/system-extensions-depa5fb8376f/web)
- 飞连 3.3.15 自带 `corplink-cli --help`、`vpn disconnect --help`、`swg disconnect --help` 和
  `/usr/local/corplink/uninstall.sh`。
- [飞连官方产品页](https://www.volcengine.com/product/feilian)
