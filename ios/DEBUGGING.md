# iOS VPN 调试日志

Runner 和 PacketTunnel 使用系统统一日志，subsystem 为
`com.champion.flClash.vpn`，每条新增日志都有 `[FlClashVPN]` 前缀。
日志区分 `Service`（主应用）、`IPC`（跨进程消息）、`PacketTunnel`
（扩展生命周期）、`Core`（Swift 调用 Go）四个 category。

修改原生 Swift 后需要重新编译、安装应用，Flutter 热重载不会更新扩展。

## 真机抓取

在 macOS Console（控制台）中选择已连接的 iPhone，开始流式传输，
筛选 subsystem `com.champion.flClash.vpn` 或文本 `[FlClashVPN]`。
先开始抓取，再启动 FlClash VPN，保留从启动到失败/停止的完整日志。
单独查看 `flutter run` 输出可能看不到扩展进程的日志。

安装了 libimobiledevice 的机器也可以运行：

```bash
idevicesyslog -u 00008110-001E702E3482401E \
  --no-colors -m '[FlClashVPN]' | tee /tmp/flclash-vpn.log
```

上面的 UDID 对应当前开发使用的 iPhone13Pro；其他设备需要替换 UDID。

## 如何定位卡点

- `startTunnel ... begin`：系统已经进入扩展启动方法。
- `sharedStateLoaded setup=true`：扩展实际读到了初始化参数。
- `configReadable=true configBytes=...`：配置文件存在且当前进程可读；不代表配置解析成功。
- `networkSettings.applied`：系统网络设置回调成功。
- `Core initClash/setupConfig ... begin/end`：核心初始化、配置加载及返回码。
- `packetFlow.lookupFD`、`startTUN ... started=true`：FD 获取和 Go TUN 创建结果。
- `startTunnel ... end=ready`：扩展完成启动。
- `Service vpnStatus=connected`：主应用收到系统已连接状态。
- `actionRoute=appCore/extension`：查询实际上发往哪个进程；主应用核心能响应并不说明 VPN 已连接。
- `lastDisconnectError`：iOS 16 及以上返回的最近断开错误。
- `pendingAfter=10s`：操作超过 10 秒未返回，仅为日志告警，不会取消操作。
- `queueWaitMs`：扩展消息在串行队列内等待至少 1 秒。
- `stopTunnel reason=...`：系统停止原因的原始枚举值，以及停止队列和 Go 清理耗时。

同一操作的 `begin`、阶段、`end` 使用相同 `id`；耗时使用单调时钟。
`requestAccepted` 仅表示系统接受启动请求，仍需等待 `vpnStatus=connected`。
正常的流量查询和事件轮询不逐条记录，只记录失败、至少 1 秒的慢调用和 10 秒未返回告警。

新增日志只公开阶段、状态、参数是否存在、数量、文件大小和耗时，
不输出配置正文、订阅 URL、节点名称或凭据。原始错误描述标记为 private，
导出后可能显示为 `<private>`；错误阶段、domain 和 code 仍可见。
既有 Flutter/Go 日志不受此过滤规则约束，分享日志时优先使用上述前缀过滤。

本次日志不会改变启动成功判定、FD 所有权、超时行为或网络检测状态，
用于复现并定位这些逻辑问题。
