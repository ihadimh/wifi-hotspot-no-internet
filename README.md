# Wi-Fi 已连接但无法上网：ARP 表为空时的分层排查

> 电脑连手机热点显示「已连接」，但无 Internet；接口有 IP 地址，ARP 表却是空的。
> 本文只记录实测数据与由数据直接得出的推断，未经验证的内容标注为「候选原因」。

中文版：[电脑连手机热点显示「已连接」却无法上网：ARP 表为空时的排查记录](https://blog.csdn.net/2401_88602546/article/details/168970765)

## English Summary

A Windows 11 laptop joined an Android phone hotspot and showed "Connected, no Internet". The fault occurred twice in one day.

Measured facts:

- Association succeeded (WPA2-Personal / AES-CCMP, 802.11ac).
- The interface held `192.168.96.9/24`, but that address came from **Windows' local DHCP lease cache** (event `50066`), not from a DHCP exchange in that session.
- The interface's **ARP table was empty** — not even the gateway — and the gateway did not answer ping. `ReceivedUnicastPackets` was 16, versus 441+ in normal operation.
- DHCP lease-renewal timed out five times that day (event `1003`, error `0x79`).

A natural contrast appeared later: when the cached lease had **expired** (event `50076`), Windows was forced to run a full DHCP exchange — and the connection worked immediately (ARP resolved, 0% loss, HTTP 200). When the cached lease was **still valid**, the connection failed.

**What this article does not claim:** a confirmed root cause. Three candidates are listed with supporting and contradicting evidence — (1) cached address conflicting with the hotspot's re-initialised DHCP pool, (2) mismatched PTK at the key layer, (3) a DHCP client stuck in a bad state. Discriminating steps are given in section 7.

Deleting and re-creating the Wi-Fi profile restored connectivity in this incident, but that action also discards the cached lease, resets the interface and forces a full handshake — so it cannot be used to prove which candidate is correct.

---

## 目录

- [1. 现象](#1-现象)
- [2. 环境](#2-环境)
- [3. 故障状态下的实测数据](#3-故障状态下的实测数据)
- [4. 一次天然对照：缓存过期后反而成功了](#4-一次天然对照缓存过期后反而成功了)
- [5. 三种候选原因](#5-三种候选原因)
- [6. 已验证有效的手段及其局限](#6-已验证有效的手段及其局限)
- [7. 下次复发时的判定步骤](#7-下次复发时的判定步骤)
- [8. 另一件独立的事：第一跳 30% 丢包](#8-另一件独立的事第一跳-30-丢包)
- [9. 排查中做过但无效的操作](#9-排查中做过但无效的操作)
- [10. 可复用的诊断清单](#10-可复用的诊断清单)
- [11. 结论](#11-结论)
- [12. 脚本](#12-脚本)

---

## 1. 现象

Windows 11 笔记本连接安卓手机热点后：

- 系统显示「已连接」，同时标注「无法访问 Internet」；
- 手机热点界面显示「没有设备连接」，或连接/断开来回跳；
- 无法打开网页，ping 不通任何地址；
- 同一天内出现两次，均发生在从校园网切换到热点之后；
- 同一热点连接另一台电脑正常；
- 用另一部不同品牌的手机开热点，同一台笔记本同样失败。

## 2. 环境

| 项目 | 实测值 |
|---|---|
| 系统 | Windows 11 |
| 无线网卡 | Intel Wi-Fi 6 AX201 160MHz |
| 驱动 | 22.250.10.1（2023-08-15，`oem67.inf`） |
| 手机热点 | OPPO，5GHz，WPA2-Personal / AES-CCMP |
| 热点信道 | 149 / 153（手机重启热点后信道会变） |
| 另一网络 | 校园网 GiWiFi，5GHz / 信道 161 / 认证 Open、加密 None |

## 3. 故障状态下的实测数据

### 3.1 关联成功

```
State        : connected
PHY 类型     : 802.11ac
身份验证     : WPA2-Personal
加密         : AES-CCMP
Signal       : 88-99%
```

关联、认证、加密协商均完成，因此系统显示「已连接」。

### 3.2 地址来自本地缓存，而非当次 DHCP 交换

`Microsoft-Windows-Dhcp-Client/Admin`，当天事件分布：

```
50067  DHCP 已收到 SSID                          79 次
50065  DHCP 已在缓存中找到 SSID 的匹配项            78 次
50066  DHCP 已使用 SSID 查明地址                   28 次
50076  DHCP 未查明地址，因为租用已过期               2 次
1003   无法从 DHCP 服务器续订地址（错误 0x79）        5 次
```

`50066` 表示从本地缓存取出此前分配过的地址直接使用，**没有与该 AP 执行 DORA**。

`50076` 出现在 `09:52:09` 与 `15:57:49`，表示缓存租约已过期、无地址可用。

### 3.3 有 IP，但 ARP 表为空、网关不通

13:21 实测（故障状态）：

```
WLAN IPv4              : 192.168.96.9/24    PrefixOrigin=Dhcp
默认网关               : 192.168.96.146
网关 ping              : 全部超时
arp -a（该接口）        : 无任何动态邻居记录，连网关条目都没有
ReceivedUnicastPackets : 16
ReceivedPacketErrors   : 0
```

正常工作时 `ReceivedUnicastPackets` 为 441 以上。

### 3.4 DHCP 续订反复超时

`1003` 事件 5 次，错误码 `0x79`（121，信号灯超时）：

```
09:51:34   12:06:18   12:27:22   13:35:25   13:45:18
```

### 3.5 热点重启后 BSSID 与信道均变化

```
a2:23:6e:48:24:2b      （较早一次）
a6:ca:db:b5:f5:65      信道 149
32:03:7e:cb:1a:df      信道 153
```

前两个第一字节置了本地管理位（bit 1），属本地生成地址。

## 4. 一次天然对照：缓存过期后反而成功了

20:16:52 连接热点时记录 `50076`（缓存租约已过期），系统被迫执行完整 DHCP 交换，随后：

```
IP              : 192.168.96.9/24   ValidLifetime = 58:29（约 1 分钟前获取）
ARP             : 192.168.96.146 -> 32-03-7e-cb-1a-df  动态
网关丢包        : 0%（5 包，2-31ms）
公网丢包        : 0%（5 包，18-36ms）
网页            : baidu 200 / 429ms，qq 200 / 306ms
```

对比 18:10 与 18:19：日志记录 `50066`（缓存有效、套用旧地址），两次均在 15 秒内失败并被切走。

| 时间 | 缓存状态 | 实际发生 | 结果 |
|---|---|---|---|
| 18:10 / 18:19 | 有效，套用旧地址 | 无 DHCP 交换 | 不通 |
| 20:16 | 已过期，无法套用 | 完整 DHCP 交换 | 正常 |

两种情况下都执行了完整 WPA2 握手，密钥层状态相同；差别在于是否重新申请地址。

## 5. 三种候选原因

三种解释都能覆盖观测到的现象，均未被证实。列出是为了说明下一步测什么。

### 候选一：缓存地址与热点重启后的实际分配冲突

手机每次重启热点，DHCP 池重新初始化。若电脑套用缓存的 `192.168.96.9`，而该地址在手机当前租约表中对应另一 MAC 或未分配，则在热点侧不可达。

- 支持：第 4 节的两组对照；删除配置后恢复（同时丢弃了缓存租约）。
- 反对：无直接证据表明该地址在热点侧被其他设备占用。

### 候选二：密钥状态不一致（PTK 层面）

有 IP 但 ARP 表为空、接收单播包极少，与「单播帧解密失败被丢弃」的特征一致。

- 支持：ARP 表完全空白，用常规 IP 层原因不易解释。
- 反对：几种情况下都执行了完整握手，无法说明为何只有某几次失败。

### 候选三：DHCP 客户端进入异常状态

`1003` 显示续订反复超时（0x79）。若 DHCP 客户端卡在异常状态，可能表现为「有地址但无法通信」。

- 支持：当天 5 次续订超时；同一时段校园网也出现加载困难。
- 反对：无法解释 ARP 表为空——ARP 不依赖 DHCP 客户端状态。

## 6. 已验证有效的手段及其局限

```powershell
netsh wlan show profiles
netsh wlan delete profile name="奕 悟"
```

删除后在系统 Wi-Fi 列表重新连接、重新输入密码。13:44 执行后各项指标同步恢复（ARP 解析成功、网关可达、0% 丢包、HTTP 200）。

**局限**：该操作同时丢弃该 SSID 的缓存租约、重置网卡接口状态、并重新执行完整握手。它有效**不能**用于证明成因是三者中的哪一个。

## 7. 下次复发时的判定步骤

### 第一步：先尝试不换配置修好

```powershell
ipconfig /release "WLAN"
ipconfig /renew "WLAN"
```

| 结果 | 说明 |
|---|---|
| 恢复 | 与地址分配相关（候选一或三），与密钥层无关 |
| 仍不通 | 缓存/地址路径不成立，倾向候选二 |
| 报错 1003 / 0x79 | DHCP 交换未完成，问题在更前面 |

这一步只需数秒且不丢失配置，应排在删除配置之前。

### 第二步：记录三组数据

```powershell
Get-NetIPAddress -InterfaceAlias WLAN -AddressFamily IPv4
arp -a
Get-NetAdapterStatistics -Name WLAN | Select-Object ReceivedUnicastPackets, OutboundUnicastPackets
```

### 第三步：抓包（需管理员）

```powershell
pktmon filter remove
pktmon filter add -i WLAN
pktmon start --capture --pkt-size 128 -f C:\Users\Public\wifi.etl
# 保持故障状态 20 秒
pktmon stop
pktmon etl2txt C:\Users\Public\wifi.etl -o C:\Users\Public\wifi.txt
```

`wifi.txt` 中 NIC / NDIS / TCPIP 各组件的计数差异，可区分「帧未到网卡」「到网卡但被丢弃」「到协议栈」。

## 8. 另一件独立的事：第一跳 30% 丢包

同一天另一时段，同一台机器连校园网时，到**第一跳网关（2ms）** 测得 30% 丢包：

```
发送 60 包，收到 42 包，丢 18 包（30%）
丢包序号: 6,7  14,15  20,21,22  25  32,33  36,37  41,42  48,49  55,56
丢包间隔: 1,7,1,5,1,1,3,7,1,3,1,4,1,6,1,6,1
```

丢包成对出现，间隔约 5-8 个包。到第一跳即丢包，问题在无线链路这一段。

```powershell
Set-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword MIMOPowerSaveMode -RegistryValue 3
Set-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword RoamAggressiveness -RegistryValue 0
```

| 属性 | 原值 | 新值 |
|---|---|---|
| `MIMOPowerSaveMode` | 自动 SMPS | 无 SMPS |
| `RoamAggressiveness` | 3. 中间 | 1. 最低值 |

连续三次复测均为 0% 丢包。

**局限**：两项同时修改，无法确定是哪一项起作用，也无法排除当时环境自行恢复。

## 9. 排查中做过但无效的操作

| 操作 | 执行后的实测结果 |
|---|---|
| 重启电脑、重启手机 | 故障依旧 |
| 关闭热点「自动连接」 | 校园网丢包 30% → 17.5%，热点故障依旧 |
| `PnPCapabilities=24` | 故障依旧 |
| MIMO 节能模式 → 无 SMPS | 校园网丢包归零，热点故障依旧 |
| 漫游主动性 → 最低值 | 同上 |
| NlaSvc 设为自动并启动 | 故障依旧 |
| 停止腾讯 ACE 反作弊驱动 `ACE-BOOT` | 故障依旧 |
| 解绑 VMware Bridge Protocol | 故障依旧 |
| `IEEE11nMode`：802.11ax → 802.11ac | 未改变结果 |

## 10. 可复用的诊断清单

```powershell
# 1 关联状态与协商参数
netsh wlan show interfaces

# 2 地址来源
Get-NetIPAddress -InterfaceAlias WLAN -AddressFamily IPv4
Get-NetIPInterface -InterfaceAlias WLAN -AddressFamily IPv4 | Select-Object Dhcp

# 3 默认路由与网关
Get-NetRoute -DestinationPrefix "0.0.0.0/0"

# 4 ARP 表
arp -a

# 5 双向计数
Get-NetAdapterStatistics -Name WLAN | Select-Object ReceivedUnicastPackets, OutboundUnicastPackets

# 6 DHCP 是缓存套用还是真实交换
Get-WinEvent -LogName "Microsoft-Windows-Dhcp-Client/Admin" -MaxEvents 40 |
    Group-Object Id | Sort-Object Count -Descending | Select-Object Name, Count

# 7 断开原因
Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 100 |
    Where-Object Id -eq 8003 | Select-Object TimeCreated, Message
```

判读：

| 观测组合 | 指向 |
|---|---|
| 有 IP、网关不通、ARP 表空 | 单播不通；先试 `ipconfig /renew`，无效再查密钥层 |
| 日志有 50076、无地址 | 缓存租约过期，问题在地址分配 |
| 日志有 50066 | 地址来自缓存，需排除热点重启后的分配冲突 |
| 有 1003 / 0x79 | DHCP 交换未完成，问题在发送方向 |
| 第一跳丢包且呈周期性 | 查网卡省电、节能模式、后台扫描 |

## 11. 结论

1. 「已连接但无法上网」不能直接归因于驱动或信号，需要先定位到具体层。
2. 核心事实：**关联成功、有 IP，但 ARP 表为空、网关不可达、单播计数极低**（16 vs 441）。
3. **IP 地址来自本地缓存，而非当次 DHCP 交换**（`50066`）。不能把「有地址」当作 DHCP 正常的证据。
4. 天然对照显示：**缓存有效时失败、缓存过期强制重新申请时成功**。地址分配层因此成为重点怀疑对象。
5. 删除并重建无线配置在本次故障中有效，但它同时清除了缓存租约、接口状态与握手状态，**不能据此断定成因**。
6. 三种候选原因均未被证实，第 7 节给出了区分它们的具体步骤。

## 12. 脚本

仓库内附 `wifi_hotspot_tool.ps1`，封装上述检查项与常用操作：

```powershell
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -State      # 只读诊断
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Hotspot    # 故障现场快照
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Baseline   # 40 包丢包测试
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Fix        # 应用低风险修改
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Reset      # 重置网络栈
powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Forget "SSID名"
```

脚本为纯 ASCII 源码，兼容 Windows PowerShell 5.1 与 PowerShell 7。修改类操作需要管理员权限。

## 参考

- [netsh wlan 命令参考](https://learn.microsoft.com/en-us/windows-server/networking/technologies/netsh/netsh-wlan)
- [IEEE 802.11i：RSNA 密钥层次（PMK / PTK / GTK）](https://en.wikipedia.org/wiki/IEEE_802.11i-2004)
- [Intel Wi-Fi 6 AX201 驱动下载](https://www.intel.com/content/www/us/en/download/19351/intel-wireless-wi-fi-drivers-for-windows-10-and-windows-11.html)

## 相关链接

- 中文版（CSDN）：[电脑连手机热点显示「已连接」却无法上网：ARP 表为空时的排查记录](https://blog.csdn.net/2401_88602546/article/details/168970765)
- 另一篇排查记录：[GitHub 2FA 配置说明（面向中国大陆用户）](https://github.com/ihadimh/github-2fa-guide)

## License

[MIT](LICENSE)
