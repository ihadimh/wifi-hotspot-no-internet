# Wi-Fi 已连接但无法上网：一次分层定位实录

> 电脑连手机热点，显示「已连接」，但无 Internet；DHCP 能拿到地址，ARP 表却是空的。
> 本文记录从现象到根因的完整排查过程，附可复用的诊断清单与 PowerShell 脚本。

中文版首发于 CSDN：[电脑连手机热点显示「已连接」却无法上网：从 ARP 表为空定位到 PMK 缓存问题](https://blog.csdn.net/2401_88602546/article/details/168970765)

## English Summary

A Windows 11 laptop joined an Android phone hotspot and showed "Connected, no Internet". The client obtained a DHCP lease but the ARP table stayed empty and the gateway was unreachable.

Key observation: **broadcast frames worked (DHCP), unicast frames did not (ARP, gateway ping)**. In WPA2-Personal these use different keys — GTK for broadcast, PTK for unicast — which points to a 4-way handshake that completed but produced a mismatched PTK.

Root cause: the saved Wi-Fi profile carried a stale PMKID cache, while the Android hotspot had changed its BSSID (Android soft AP randomises the BSSID on every enable). Deleting the profile and re-pairing forced a full handshake and resolved it immediately.

---

## 目录

- [1. 现象](#1-现象)
- [2. 环境](#2-环境)
- [3. 先行排除的项](#3-先行排除的项)
- [4. 关键观测](#4-关键观测)
- [5. 推理：广播能通，单播不通](#5-推理广播能通单播不通)
- [6. 根因](#6-根因)
- [7. 修复与验证](#7-修复与验证)
- [8. 附带解决：第一跳 30% 周期性丢包](#8-附带解决第一跳-30-周期性丢包)
- [9. 为什么通用教程无效](#9-为什么通用教程无效)
- [10. 可复用的诊断清单](#10-可复用的诊断清单)
- [11. 脚本](#11-脚本)
- [参考](#参考)

---

## 1. 现象

- 电脑显示「已连接」，同时标注「无法访问 Internet」；
- 手机热点界面显示「没有设备连接」，或连接/断开来回跳；
- 无法打开网页，ping 不通任何地址；
- 反复断开重连，表现一致；
- 同一热点连接另一台电脑正常；
- 换另一部不同品牌的手机开热点，同一台笔记本同样失败。

手机侧的自检结论明确：热点本身正常，手机用移动数据上网正常，未设置流量限制或设备白名单。

## 2. 环境

| 项目 | 值 |
|---|---|
| 系统 | Windows 11 |
| 无线网卡 | Intel Wi-Fi 6 AX201 160MHz |
| 驱动 | 22.250.10.1（2023-08-15，`oem67.inf`） |
| 手机 | OPPO，热点 5GHz / 信道 149 / WPA2-Personal / CCMP |
| 对照网络 | 校园网 GiWiFi，5GHz / 信道 161 / 开放认证（无加密） |

对照网络（开放认证）工作正常，加密热点异常。这一差异起初被忽略，后来成为重要线索。

## 3. 先行排除的项

| 操作 | 结果 |
|---|---|
| 重启电脑 / 重启手机 | 无效 |
| 关闭热点「自动连接」 | 丢包 30% → 17.5%，热点仍不通 |
| `PnPCapabilities=24`（禁止网卡省电关闭） | 无效 |
| MIMO 节能模式 → 无 SMPS | 校园网丢包归零，热点仍不通 |
| 漫游主动性 → 最低值 | 同上 |
| NlaSvc 设为自动并启动 | 无效 |
| 停止腾讯 ACE 反作弊驱动 `ACE-BOOT` | 无效 |
| 解绑 VMware Bridge Protocol | 无效 |
| `IEEE11nMode` ax → ac | 未改变结果 |
| 扫描近三天驱动文件变动 | 仅 `ACE-ADVT.sys` 有更新，但与时间线不符 |

其中 ACE 与 VMware 桥接是两个较可疑的第三方组件：ACE 是内核级反作弊驱动，常驻运行；VMware 桥接协议在无线网卡上属于不受支持的配置。实测停用后故障不变，均排除。

## 4. 关键观测

### 4.1 DHCP 成功，ARP 表为空

```
WLAN IPv4     : 192.168.96.9/24    origin=Dhcp    state=Preferred
默认网关      : 192.168.96.146
DHCP 启用     : Enabled
网关 ping     : 全部超时
arp -a        : 该接口下无任何动态邻居记录（连网关条目都没有）
ReceivedUnicastPackets : 16        （正常工作时为 441）
ReceivedPacketErrors   : 0
```

地址分配成功说明 DHCP 交互完成过；ARP 表空白说明网关的应答从未到达本机。

### 4.2 握手次数异常放大

事件日志 `Microsoft-Windows-WLAN-AutoConfig/Operational`，故障当天：

```
8001  成功连接           29 次
11010 安全功能启动       50 次（平时 1-12 次）
11004 安全功能停止       49 次
8003  断开               23 次，其中 7 次为「网络被驱动程序断开连接」
```

握手次数比平时高一个数量级，链路在反复重新协商。

### 4.3 BSSID 变了

```
故障时：BSSID = a2:23:6e:48:24:2b
恢复后：BSSID = a6:ca:db:b5:f5:65
```

两者的第一字节 `a2` / `a6` 都置了本地管理位（bit 1），这是 Android 软 AP 随机生成 BSSID 的典型特征。手机关机、重启、切换频段都会产生新的 BSSID。

## 5. 推理：广播能通，单播不通

把两个观测组合起来：

- **DHCP 成功** → 广播帧能正常收发。客户端还没有 IP 时，安卓热点的 DHCP OFFER/ACK 以广播形式发出。
- **ARP 失败** → 单播帧收不到。ARP 应答是单播。

WPA2-Personal 中两类帧使用不同密钥：

| 帧类型 | 密钥 | 来源 |
|---|---|---|
| 广播 / 多播 | **GTK**（组临时密钥） | 4 次握手后由 AP 加密下发 |
| 单播 | **PTK**（成对临时密钥） | 4 次握手时双方各自 KDF 派生 |

由此可推断：**4 次握手流程走完了，但双方派生的 PTK 不一致**。单播帧 MIC 校验失败后被静默丢弃，广播帧用 GTK 解密正常。

这解释了最初看起来矛盾的现象：能拿到 IP，但完全无法通信；Windows 仍显示「已连接」，因为链路层关联确实存在。

## 6. 根因

Windows 的无线配置文件中缓存 **PMKID**，用于快速重连与漫游（避免每次重新做完整密钥推导）。该配置文件创建于三个月前，期间经历多次断连、手机重启、BSSID 变化。

当 AP 换了 BSSID 并重新生成密钥，而客户端仍使用旧缓存中的 PMKID 派生时：

1. 握手消息序列可以正常完成，双方状态机都返回成功；
2. 但派生出的 PTK 与 AP 侧不一致；
3. 结果即「广播通、单播断」。

**关于验证边界的说明**：这是基于上述证据的推断，未做空口抓包验证——Windows 下 Intel 网卡不提供监听模式。支持该解释的间接证据包括：DHCP 成功、ARP 空表、单播计数极低（16 vs 441）、BSSID 变化、以及重建握手后故障立即消失。

## 7. 修复与验证

```powershell
# 查看所有配置文件
netsh wlan show profiles

# 删除出问题的配置（名称含中文或空格时需加引号）
netsh wlan delete profile name="奕 悟"
```

删除后在系统 Wi-Fi 列表重新连接、重新输入密码。该操作强制清空 PMKID 缓存，完整执行一次 4 次握手。

验证数据：

```
网关 ping      : 来自 192.168.96.146 的回复，13ms，TTL=64
ARP 表         : 192.168.96.146 -> a6-ca-db-b5-f5-65  动态
ReceivedUnicastPackets : 441
网关丢包       : 0%（20 包），3-10ms
公网 223.5.5.5 : 0%（6 包），26-98ms
DNS            : baidu 235ms，qq 18ms
HTTP           : baidu 200 / 472ms，qq 200 / 259ms
```

## 8. 附带解决：第一跳 30% 周期性丢包

同一台机器在校园网下，到**第一跳网关（2ms）** 就有 30% 丢包：

```
发送 60 包，收到 42 包，丢 18 包（30%）
丢包序号: 6,7  14,15  20,21,22  25  32,33  36,37  41,42  48,49  55,56
丢包间隔: 1,7,1,5,1,1,3,7,1,3,1,4,1,6,1,6,1
```

丢包成对出现、间隔约 5-8 个包。第一跳即丢包，与上游拥塞无关，属于本机无线链路问题。

修改两项网卡高级属性后归零：

```powershell
Set-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword MIMOPowerSaveMode -RegistryValue 3
Set-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword RoamAggressiveness -RegistryValue 0
```

| 属性 | 原值 | 新值 | 作用 |
|---|---|---|---|
| `MIMOPowerSaveMode` | 自动 SMPS | 无 SMPS | 消除省电/满功率切换窗口内的丢帧 |
| `RoamAggressiveness` | 3. 中间 | 1. 最低值 | 减少后台扫描，避免离信道期间丢包 |

连续三次复测均为 **0% 丢包**。

补充一项：同机另一个根因是 `PnPCapabilities` 未设置，系统默认允许在省电时关闭网卡，一并设为 `24`。

## 9. 为什么通用教程无效

搜「电脑连不上手机热点」，主流方案集中在重启网卡、忘记网络重连、更新驱动、关闭防火墙、重置网络。这些方案对本次故障无效，因为它们**没有区分故障发生在哪一层**。

本次故障的观测把位置限定得很死：

| 观测 | 排除的可能 |
|---|---|
| 能拿到 DHCP 地址 | 关联失败、DHCP 服务异常 |
| ARP 表空、网关不通 | DNS、防火墙、路由、代理 |
| 广播通、单播不通 | 信号弱、干扰、IP 冲突 |
| 换手机换热点均失败、换电脑正常 | 手机侧问题 |

缺少「广播通、单播不通」这个区分，排查容易在「重启网卡、换驱动」中循环。

## 10. 可复用的诊断清单

```powershell
# 1 链路状态：是否关联，协商的协议/频段/速率
netsh wlan show interfaces

# 2 地址来源：DHCP 租约还是 169.254 自动地址
Get-NetIPAddress -InterfaceAlias WLAN -AddressFamily IPv4
Get-NetIPInterface -InterfaceAlias WLAN -AddressFamily IPv4 | Select-Object Dhcp

# 3 默认路由与网关
Get-NetRoute -DestinationPrefix "0.0.0.0/0"

# 4 ARP 表：是否解析出网关（关键判据）
arp -a

# 5 单播收发计数：与正常状态对比
Get-NetAdapterStatistics -Name WLAN | Select-Object ReceivedUnicastPackets, ReceivedPacketErrors

# 6 握手与断开历史
Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 200 |
    Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5

# 7 断开原因
Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 100 |
    Where-Object Id -eq 8003 | Select-Object TimeCreated, Message
```

判读：

| 观测组合 | 指向 |
|---|---|
| 有 IP、网关不通、ARP 表空 | 单播不通，优先查加密/密钥层（本文场景） |
| 有 IP、网关通、公网不通 | 上行或路由问题 |
| 拿到 169.254 地址 | DHCP 未完成，问题在关联或 DHCP 之前 |
| 第一跳丢包且呈周期性 | 网卡省电、节能模式、后台扫描 |

## 11. 脚本

仓库内附 `wifi_hotspot_tool.ps1`，把上述检查项与常用修复动作封装成模式：

```powershell
# 只读诊断：关联、地址、网关、ARP、卸载设置
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -State

# 故障现场快照（已连接但无 Internet 时运行）
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Hotspot

# 丢包基线测试：40 包到网关，输出丢包序号与间隔特征
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Baseline

# 应用低风险修复：禁止网卡省电、MIMO 无 SMPS、漫游最低、启动 NlaSvc
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Fix

# 重置网络栈：解绑 VMware 桥接、winsock/ip reset、重载网卡
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Reset

# 删除指定无线配置
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Forget "SSID名"
```

脚本为纯 ASCII 源码，兼容 Windows PowerShell 5.1 与 PowerShell 7，避免无 BOM 的 UTF-8 脚本在 5.1 下出现解析错误。修改类操作需要管理员权限。

## 参考

- [netsh wlan 命令参考](https://learn.microsoft.com/en-us/windows-server/networking/technologies/netsh/netsh-wlan)
- [802.11 密钥层次：PMK / PTK / GTK](https://en.wikipedia.org/wiki/IEEE_802.11i-2004)
- [PMK 缓存与漫游](https://www.cisco.com/c/en/us/support/docs/wireless-mobility/wireless-lan-wlan/116493-technote-technology-00.html)
- [Intel Wi-Fi 6 AX201 驱动下载](https://www.intel.com/content/www/us/en/download/19351/intel-wireless-wi-fi-drivers-for-windows-10-and-windows-11.html)

## 相关链接

- 中文版（CSDN）：[电脑连手机热点显示「已连接」却无法上网：从 ARP 表为空定位到 PMK 缓存问题](https://blog.csdn.net/2401_88602546/article/details/168970765)
- 另一篇排查记录：[GitHub 2FA 配置说明（面向中国大陆用户）](https://github.com/ihadimh/github-2fa-guide)

## License

[MIT](LICENSE)
