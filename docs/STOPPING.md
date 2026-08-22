# 停止语义、原理与验证

## 先说结论

App 提供两种语义明确的操作：

- **停止连接服务**：只停止 VPN/SWG 和 `com.volcengine.corplink.service`，可以热启动恢复。
- **开始整套 / 停止整套**：启动或停止下表中的全部已知组件，不删除飞连文件；开始不参考停止前状态。

在 2026-08-23 对 macOS 26.6.2、CorpLink 3.3.15 的实机审计中，飞连至少安装了以下独立任务：

| launchd 标签 | 作用或可执行文件 | 连接服务停止 | 整套停止 |
| --- | --- | --- | --- |
| `com.volcengine.corplink.service` | 连接主服务 `corplink-service` | 是 | 是 |
| `com.volcengine.corplink.systemextension` | firewall、EDR、EDLP、AV、设备管控等 | 否 | 是 |
| `com.corplink.networkmonitor` | `NetworkMonitor` | 否 | 是；开始时重新注册，失败则需重启 |
| `com.corplink.data_forwarder` | 策略数据转发 | 否 | 是 |
| `com.corplink.mdm.policy` | MDM 策略 | 否 | 是 |
| `com.volcengine.corplink.agent` | `CorplinkNe` 网络扩展代理 | 否 | 是 |
| `com.corplink.appblocker` | 应用管控 | 否 | 是 |
| `CorpLink` | 用户登录项 | 否 | 是 |

界面逐项展示每个任务是否加载、PID、plist 属性、策略禁用状态以及是否需要重启，不会把部分停止误报成
整套退出。

## 为什么不能把所有进程直接杀掉

多个飞连任务设置了 `KeepAlive=true`。根据 macOS 的 `launchd.plist(5)` 系统手册，`KeepAlive`
会要求 launchd 持续维持进程；只执行 `kill` 或 `launchctl stop`，进程会被再次拉起。

`com.corplink.networkmonitor` 还设置了 `LaunchOnlyOnce=true`。系统手册将它定义为：同一个任务实例只应
运行一次。实机验证表明，在执行 `bootout` 移除旧任务后，使用同一个原始 plist 重新
`bootstrap` 会创建新的任务实例并再次执行。App 因此不修改厂商 plist、不删除 `LaunchOnlyOnce`，也不直接
运行二进制，而是重新注册并验证 launchd job 与 PID；若验证失败，仍要求重启 Mac。

需要彻底移除全部组件时，应使用组织管理员认可的飞连卸载流程。飞连 3.3.15 自带的
`/usr/local/corplink/uninstall.sh` 也采用了卸载 Network Extension、停止守护任务并删除组件的流程；
它不是普通的可逆开关。

## 整套停止与开始

整套停止执行以下流程：

1. 用官方 CLI 请求 VPN、SWG 主动断开。
2. 保存客户端登录项原始内容等恢复信息，但不把它作为下次“开始”的启动范围。
3. 先停用户层客户端、网络代理和应用管控，再停 system domain 中的连接、策略、网络监控和系统防护任务。
4. 每个任务都使用其准确的 launchd domain 执行 `bootout`，而不是只杀进程。
5. 若任务已卸载但对应进程仍在，先 `SIGTERM`，两秒后才对残留进程使用 `SIGKILL`。
6. 每个 plist 只临时移除原先实际存在的 `schg/uchg`，操作后恢复完全相同的属性集合。
7. 全部处理后再观察 5 秒；任何任务或进程复活都会判为失败。
8. 如果检测到仍活跃的飞连 System Extension，也不会报告“干净停止”。为了保持可恢复性，本工具不会把
   System Extension 执行卸载；彻底注销它属于卸载语义。

开始时不参考停止前是否运行，按系统防护、网络监控、连接、策略、用户代理和客户端的依赖顺序，对所有已安装且
未被禁用的组件执行 `launchctl bootstrap`，并逐项验证。系统或组织策略标记为 disabled 的任务不会被强制
enable。网络监控同样使用原始 plist 重新注册，不会删除 `LaunchOnlyOnce`。

整套只有同时满足以下条件才显示为“已干净停止”：8 个已知任务均未加载、对应已知进程及
Finder Sync / SealSuite 辅助进程全部不存在、没有已激活的已知飞连 System Extension。plist 和 App 文件仍保留，因为这是
停止而不是卸载。

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

脚本退出码：`0` 表示至少有整套组件正在运行且状态一致，`3` 表示所有已知任务、进程及活跃扩展均不存在，
`1` 表示任务与常驻进程状态不一致。

## 2026-08-23 实机闭环验证

### 整套启动与 NetworkMonitor 热启动（1.4.0）

验证环境：macOS 26.6.2、CorpLink 3.3.15、飞连控制 1.4.0。开始前连接主服务和网络监控均未加载，
恢复快照只剩 `network-monitor`；在主界面执行一次“开始”并完成管理员授权：

| 检查项 | 结果 |
| --- | --- |
| 整套启动范围 | 不读取停止前运行范围；启动全部已安装且未被策略禁用的组件 |
| 启动后任务 | 7 / 8 已加载；唯一未启动的是组织策略明确禁用的 MDM |
| 连接主服务 | `system/com.volcengine.corplink.service` 状态为 running，PID `73517`，`runs=1`，从未退出 |
| NetworkMonitor | 使用未修改的原始 plist 重新 `bootstrap` 成功，状态为 running，PID `73495`，仍保留 `launch only once` 属性 |
| 延时稳定性 | 25 秒后两个 PID 均未变化，两个任务仍为 `runs=1`、从未退出 |
| 恢复快照 | 启动验证通过后快照已清空，不再残留“需要恢复”的假状态 |
| VPN / SWG | 官方 CLI 均返回 disconnected；主服务状态接口已恢复可查询 |
| 网络稳定性 | 延时观察前后的系统代理、DNS、规范化 IPv4 路由哈希完全一致 |
| NetworkMonitor 日志 | 本次与重启前原始实例均报告无法取得 SSID 后跳过处理；不是重新注册引入的新错误，未出现崩溃或反复拉起 |

另使用无网络副作用的临时 `LaunchOnlyOnce` 用户任务验证了当前 macOS 行为：任务执行并退出后，使用同一原始
plist 再次 `bootstrap` 能创建新任务实例并再次执行。测试后任务与临时文件均已移除。这个结果说明不必删除
`LaunchOnlyOnce` 或直接启动厂商二进制；但不同 macOS 或飞连版本仍可能有差异，因此 App 每次都以 launchd
状态和实际 PID 验证为准，失败时明确要求重启。

### 整套停止与恢复（1.3.0）

验证环境：macOS 26.6.2、CorpLink 3.3.15、飞连控制 1.3.0。连续执行了两轮真实的
“停止整套 → 延时审计 → 恢复停止前状态”：

| 检查项 | 结果 |
| --- | --- |
| 停止前基线 | 8 个任务中 6 个已加载，12 个已知相关进程；MDM 原本由策略禁用，连接主服务原本已停止 |
| 停止后任务与进程 | 0 / 8 已加载、0 个已知相关进程，helper 退出码为 `3` |
| 防复活观察 | 内置 5 秒观察通过；额外的 8 秒和 20 秒延时复查仍保持 0 / 8、0 进程 |
| System Extension | 未发现 `activated enabled` 的已知飞连 System Extension |
| plist 保护 | 三个原有 `schg` 的 plist 在停止后均恢复为 `schg` |
| 网络配置 | DNS、系统代理、规范化 IPv4 路由和 IPv6 路由最终均与停止前基线一致；IPv4 `utun` 路由为 0 |
| 恢复结果 | 系统防护、策略转发、网络代理、应用管控和客户端均恢复；原本关闭的连接服务和原本禁用的 MDM 未被擅自开启 |
| NetworkMonitor | 正确保留为“需要重启恢复”，恢复快照中只剩 `network-monitor` |
| 用户登录项 | 第二轮快照保存 plist 原始字节；恢复后 `CorpLink.plist` 格式有效、所有者 `sunyi:staff`、权限 `0644`，延时复查仍存在 |

第一轮恢复时发现 CorpLink 客户端启动后会删除旧的用户 LaunchAgent 文件。1.3.0 因此增加了登录项原始字节、
所有者和权限的快照恢复，并通过第二轮真实停止/恢复验证。这个修复避免了“当前进程恢复，但下次登录无法启动”
的隐蔽问题。

### 连接服务停止（1.2.0）

以下是连接服务模式的验证，环境为 macOS 26.6.2、CorpLink 3.3.15、飞连控制 1.2.0。测试不是只看一次按钮状态，
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
