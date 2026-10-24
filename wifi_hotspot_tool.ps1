#Requires -Version 5.1
<#
    Wi-Fi hotspot / packet-loss diagnostic tool.
    ASCII-only source on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI
    when the file has no BOM, which breaks non-ASCII source text.
    Chinese / localized adapter values are read at RUNTIME from the driver,
    so the script works on any UI language.

    Usage:
      powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -State
      powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Baseline
      powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Fix
      powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Report
      powershell -ExecutionPolicy Bypass -File .\wifi_hotspot_tool.ps1 -Forget "SSID"

    What -Fix changes:
      F1  NIC power-off permission  -> 24 (never power off to save energy)
      F2  MIMO power save mode      -> last allowed value (usually "No SMPS")
      F3  802.11 mode               -> the 802.11ac entry, if present
      F4  Roaming aggressiveness    -> first allowed value (lowest)
      F5  NlaSvc                    -> Automatic + started
#>

param(
    [switch]$State,
    [switch]$Baseline,
    [switch]$Hotspot,
    [switch]$Fix,
    [switch]$Reset,
    [switch]$Report,
    [string]$Forget
)

$ErrorActionPreference = "Continue"
$script:LogPath = Join-Path $PSScriptRoot ("wifi_diag_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

function Say {
    param([string]$Text = "")
    Write-Host $Text
    try { Add-Content -LiteralPath $script:LogPath -Value $Text -Encoding UTF8 } catch {}
}

function Head {
    param([string]$Title)
    Say ""
    Say ("=" * 64)
    Say $Title
    Say ("=" * 64)
}

# Set an advanced property by index into its allowed-value list.
# Returns $true on success. Prints what it did either way.
function Set-PropByIndex {
    param($Prop, [int]$Index, [string]$Note)

    Say ("  Property : " + $Prop.DisplayName + "   [" + $Prop.RegistryKeyword + "]")
    Say ("  Current  : " + $Prop.DisplayValue + "   (registry=" + $Prop.RegistryValue + ")")
    Say ("  Allowed  : " + (($Prop.ValidDisplayValues) -join " | "))
    if ($Note) { Say ("  Strategy : " + $Note) }

    $disp = @($Prop.ValidDisplayValues)
    $regs = @($Prop.ValidRegistryValues)
    if ($disp.Count -eq 0 -or $regs.Count -eq 0) {
        Say "  No allowed-value list reported by the driver. Skipped."
        return $false
    }
    if ($Index -lt 0 -or $Index -ge $regs.Count) {
        Say ("  Index " + $Index + " out of range (0.." + ($regs.Count - 1) + "). Skipped.")
        return $false
    }

    $targetDisplay = $disp[$Index]
    $targetReg = $regs[$Index]
    try {
        Set-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword $Prop.RegistryKeyword -RegistryValue $targetReg -ErrorAction Stop
        $after = Get-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword $Prop.RegistryKeyword -ErrorAction SilentlyContinue
        $now = if ($after) { $after.DisplayValue } else { "?" }
        Say ("  Set to   : " + $targetDisplay + " (registry=" + $targetReg + ") -> verified: " + $now)
        return $true
    } catch {
        Say ("  Set failed: " + $_.Exception.Message)
        Say ("  Do it manually in Device Manager, Advanced tab: set '" + $Prop.DisplayName + "' to '" + $targetDisplay + "'")
        return $false
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Say ("Log file        : " + $script:LogPath)
Say ("Running as admin: " + $isAdmin)

if (-not ($State -or $Baseline -or $Fix -or $Report -or $Forget)) { $State = $true }

# ------------------------------------------------------------------ STATE
if ($State) {
    Head "1. WLAN interface"
    (netsh wlan show interfaces) | ForEach-Object { Say $_ }

    Head "2. Current associations (is the PC connected to the hotspot as well?)"
    $np = Get-NetConnectionProfile -ErrorAction SilentlyContinue
    if ($np) {
        $np | ForEach-Object {
            Say ("  " + $_.Name + " | adapter=" + $_.InterfaceAlias + " | category=" + $_.NetworkCategory + " | IPv4=" + $_.IPv4Connectivity)
        }
    } else { Say "  (none)" }

    Head "3. Wi-Fi Direct / virtual adapters"
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Wi-Fi Direct|Virtual WiFi|Hosted' } |
        Select-Object Name, InterfaceDescription, Status |
        Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_ }

    Head "4. IP configuration and default routes"
    Get-NetIPConfiguration -ErrorAction SilentlyContinue | ForEach-Object {
        Say ("  " + $_.InterfaceAlias + " [" + $_.NetAdapter.Status + "]  IPv4=" + $_.IPv4Address.IPAddress + "/" +
            $_.IPv4Address.PrefixLength + "  GW=" + $_.IPv4DefaultGateway.NextHop)
    }
    Say ""
    Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias, NextHop, RouteMetric, InterfaceMetric |
        Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_ }

    Head "5. Saved profiles ([auto] = connects by itself)"
    $dir = "C:\ProgramData\Microsoft\Wlansvc\Profiles\Interfaces"
    Get-ChildItem $dir -Recurse -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object {
        $raw = Get-Content $_.FullName -Raw
        $ssid = if ($raw -match '<name>(.*?)</name>') { $matches[1] } else { "?" }
        $mode = if ($raw -match '<connectionMode>(.*?)</connectionMode>') { $matches[1] } else { "?" }
        $rand = if ($raw -match 'macRandomizationMode>(\w+)<') { $matches[1] } else { "notset" }
        Say ("  [" + $mode + "] SSID=" + $ssid + "  macRandom=" + $rand)
    }

    Head "6. Driver and the properties this tool can change"
    Get-NetAdapter -Name WLAN -ErrorAction SilentlyContinue |
        Select-Object DriverVersion, DriverDate, DriverProvider, LinkSpeed |
        Format-List | Out-String | ForEach-Object { Say $_ }
    Get-NetAdapterAdvancedProperty -Name WLAN -ErrorAction SilentlyContinue |
        Where-Object { $_.RegistryKeyword -match 'SMPS|MIMO|Roam|WirelessMode|802' } |
        Select-Object DisplayName, RegistryKeyword, DisplayValue, RegistryValue |
        Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_ }

    Head "7. Services"
    Get-Service WlanSvc, Dhcp, Dnscache, NlaSvc, BFE -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType |
        Format-Table -AutoSize | Out-String | ForEach-Object { Say $_ }

    Head "8. NIC power-off permission (PnPCapabilities; 24 = never power off)"
    $nic = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'AX201|Wi-Fi' -and $_.FriendlyName -notmatch 'Direct' }
    foreach ($d in $nic) {
        $val = (Get-ItemProperty -Path ("HKLM:\SYSTEM\CurrentControlSet\Enum\" + $d.InstanceId) -ErrorAction SilentlyContinue).PnPCapabilities
        $shown = if ($null -ne $val) { $val } else { "notset (default allows power-off)" }
        Say ("  " + $d.FriendlyName + " -> PnPCapabilities=" + $shown)
    }
}

# ---------------------------------------------------------------- HOTSPOT
# Run this WHILE connected to the phone hotspot and BEFORE it works again,
# i.e. exactly when Windows says "connected" but there is no Internet.
if ($Hotspot) {
    Head "H1. Link state (what Windows thinks it has)"
    (netsh wlan show interfaces) | ForEach-Object { Say $_ }

    Head "H2. Addresses on WLAN (169.254.x.x = DHCP never completed)"
    $ip = Get-NetIPAddress -InterfaceAlias WLAN -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ip) {
        foreach ($a in $ip) {
            Say ("  " + $a.IPAddress + "/" + $a.PrefixLength + "  origin=" + $a.PrefixOrigin + "  state=" + $a.AddressState)
        }
        if (@($ip | Where-Object { $_.IPAddress -like '169.254.*' }).Count -gt 0) {
            Say "  >> APIPA address: DHCP did NOT hand out a lease. This is the failure."
        }
    } else { Say "  no IPv4 address on WLAN at all" }

    Head "H3. DHCP enabled? lease info?"
    $dh = Get-NetIPInterface -InterfaceAlias WLAN -AddressFamily IPv4 -ErrorAction SilentlyContinue
    Say ("  Dhcp=" + $dh.Dhcp + "  ConnectionState=" + $dh.ConnectionState)
    Say ("  Route to 0.0.0.0/0: " + ((Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.InterfaceAlias + "->" + $_.NextHop }) -join "; "))

    Head "H4. Is the gateway of OUR subnet reachable?"
    $ownIp = ($ip | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
    if (-not $ownIp) {
        Say "  No usable IPv4 on WLAN (APIPA or nothing)."
        Say "  >> This means DHCP never completed: the adapter associated, but nobody handed out a lease."
    } else {
        Say ("  Our WLAN address: " + $ownIp)
        # Prefer the real default gateway; only guess .1 in the same /24 when there is none.
        $realGw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Sort-Object InterfaceMetric | Select-Object -First 1).NextHop
        if ($realGw) {
            $gwGuess = $realGw
            Say ("  Default gateway: " + $gwGuess)
        } else {
            $parts = $ownIp.Split('.')
            $gwGuess = ($parts[0..2] -join '.') + '.1'
            Say ("  No default gateway. Probing assumed subnet gateway: " + $gwGuess)
        }
        $out = cmd /c "ping -n 2 -w 900 $gwGuess"
        $hit = @($out | Where-Object { $_ -match ([regex]::Escape($gwGuess) + '\D.*TTL=') })
        if ($hit.Count -gt 0) { Say ("  OK: " + $hit[0].Trim()) }
        else {
            Say ("  NO REPLY from " + $gwGuess)
            Say "  >> Associated but the gateway is not reachable. DHCP/gateway problem, not a DNS problem."
        }
    }
    Say "  Note: on large campus L2 segments, other 192.168.x.x hosts may answer; that says nothing about the hotspot."

    Head "H5. ARP table on WLAN"
    (arp -a) | Select-String "192\.168|172\.20|Interface" | ForEach-Object { Say ("  " + $_.Line.Trim()) }

    Head "H6. Adapter counters"
    Get-NetAdapterStatistics -Name WLAN -ErrorAction SilentlyContinue |
        Select-Object ReceivedUnicastPackets, OutboundUnicastPackets, ReceivedPacketErrors |
        Format-List | Out-String | ForEach-Object { Say $_ }

    Head "H7. DHCP client events (last 60 minutes)"
    Get-WinEvent -LogName "Microsoft-Windows-Dhcp-Client/Admin" -MaxEvents 30 -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -ge (Get-Date).AddMinutes(-60) } |
        Select-Object -First 15 TimeCreated, Id, LevelDisplayName |
        Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_ }
    Get-WinEvent -LogName System -MaxEvents 400 -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -ge (Get-Date).AddMinutes(-30) -and $_.ProviderName -match 'Dhcp|Netwtw|WLAN' } |
        Select-Object -First 15 TimeCreated, ProviderName, Id, LevelDisplayName |
        Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_ }

    Head "H8. Current advanced settings (what -Fix already changed)"
    Get-NetAdapterAdvancedProperty -Name WLAN -ErrorAction SilentlyContinue |
        Where-Object { $_.RegistryKeyword -match 'SMPS|MIMO|Roam|IEEE11nMode|WirelessMode' } |
        Select-Object DisplayName, RegistryKeyword, DisplayValue |
        Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Say $_ }

    Say ""
    Say "Send this log. It shows whether DHCP ever started, or died at association."
}

# --------------------------------------------------------------- BASELINE
if ($Baseline) {
    Head "9. Baseline packet-loss test (40 packets to the gateway)"
    $gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object InterfaceMetric | Select-Object -First 1).NextHop
    if (-not $gw) {
        Say "  No default gateway. Are you connected?"
    } else {
        Say ("  Gateway: " + $gw)
        Say "  Sending 40 packets (slow when loss is high)..."
        $raw = cmd /c "chcp 437 >nul & ping -n 40 $gw"
        $seq = 0
        $lost = @()
        foreach ($line in $raw) {
            if ($line -match 'Reply from') { $seq++ }
            elseif ($line -match 'timed out|unreachable') { $seq++; $lost += $seq }
        }
        $pct = [math]::Round(100.0 * $lost.Count / 40, 1)
        Say ("  Sent=40  Received=" + (40 - $lost.Count) + "  Lost=" + $lost.Count + "  Loss=" + $pct + "%")
        if ($lost.Count -gt 0) {
            Say ("  Lost at packet #: " + ($lost -join ","))
            if ($lost.Count -ge 2) {
                $gaps = @()
                for ($i = 1; $i -lt $lost.Count; $i++) { $gaps += ($lost[$i] - $lost[$i - 1]) }
                Say ("  Gap between losses: " + ($gaps -join ","))
                Say "  Gaps clustering around 5-8 => periodic bursts (power save / roaming scan)."
            }
        } else {
            Say "  No loss at all. Link layer looks clean."
        }
        ($raw | Select-String 'Minimum|Average|Maximum') | ForEach-Object { Say ("  " + $_.Line.Trim()) }
    }
}

# -------------------------------------------------------------------- FIX
if ($Fix) {
    $props = @()
    if ($isAdmin) { $props = @(Get-NetAdapterAdvancedProperty -Name WLAN -ErrorAction SilentlyContinue) }

    Head "F1. NIC power-off permission -> 24 (never power off)"
    if ($isAdmin) {
        $nic = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -match 'AX201|Wi-Fi' -and $_.FriendlyName -notmatch 'Direct' }
        foreach ($d in $nic) {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\" + $d.InstanceId
            try {
                Set-ItemProperty -Path $key -Name PnPCapabilities -Value 24 -Type DWord -ErrorAction Stop
                Say ("  OK   " + $d.FriendlyName)
            } catch { Say ("  FAIL " + $d.FriendlyName + " -> " + $_.Exception.Message) }
        }
    } else { Say "  Needs admin. Skipped." }

    Head "F2. MIMO power save -> last allowed value (usually No SMPS)"
    if ($isAdmin) {
        $p = $props | Where-Object { $_.RegistryKeyword -eq 'MIMOPowerSaveMode' } | Select-Object -First 1
        if (-not $p) { $p = $props | Where-Object { $_.RegistryKeyword -match 'SMPS' } | Select-Object -First 1 }
        if ($p) {
            $idx = @($p.ValidRegistryValues).Count - 1
            $null = Set-PropByIndex -Prop $p -Index $idx -Note "taking the last entry, which is the no-power-save option"
            Say "  NOTE: a brief disconnect may occur."
        } else { Say "  MIMO/SMPS property not found. Skipped." }
    } else { Say "  Needs admin. Skipped." }

    Head "F3. 802.11 mode -> the 802.11ac entry"
    if ($isAdmin) {
        # Intel exposes two properties: IEEE11nMode (n/ac/ax) and WirelessMode (a/b/g).
        # Only IEEE11nMode has an 802.11ac entry, so target it explicitly.
        $p = $props | Where-Object { $_.RegistryKeyword -eq 'IEEE11nMode' } | Select-Object -First 1
        if (-not $p) {
            $p = $props | Where-Object {
                $_.DisplayName -match '802\.11n/ac/ax' -or ($_.DisplayName -match '802\.11' -and (@($_.ValidDisplayValues) -match 'ax'))
            } | Select-Object -First 1
        }
        if ($p) {
            $disp = @($p.ValidDisplayValues)
            $idx = -1
            for ($i = 0; $i -lt $disp.Count; $i++) {
                if ($disp[$i] -match '802\.11ac' -and $disp[$i] -notmatch 'ax') { $idx = $i; break }
            }
            if ($idx -ge 0) {
                $null = Set-PropByIndex -Prop $p -Index $idx -Note "picking the plain 802.11ac entry"
            } else {
                Say ("  No 802.11ac entry. Allowed: " + ($disp -join " | "))
            }
        } else { Say "  802.11 mode property not found. Skipped." }
    } else { Say "  Needs admin. Skipped." }

    Head "F4. Roaming aggressiveness -> first allowed value (lowest)"
    if ($isAdmin) {
        $p = $props | Where-Object { $_.RegistryKeyword -eq 'RoamAggressiveness' } | Select-Object -First 1
        if (-not $p) { $p = $props | Where-Object { $_.RegistryKeyword -match 'Roam' -and $_.RegistryKeyword -notmatch 'Band' } | Select-Object -First 1 }
        if ($p) {
            $null = Set-PropByIndex -Prop $p -Index 0 -Note "taking the first entry = lowest aggressiveness"
        } else { Say "  Roaming property not found. Skipped." }
    } else { Say "  Needs admin. Skipped." }

    Head "F5. NlaSvc -> Automatic and started"
    if ($isAdmin) {
        try {
            Set-Service NlaSvc -StartupType Automatic -ErrorAction Stop
            if ((Get-Service NlaSvc).Status -ne "Running") { Start-Service NlaSvc -ErrorAction Stop }
            $s = Get-Service NlaSvc
            Say ("  Status=" + $s.Status + "  StartType=" + $s.StartType)
        } catch { Say ("  FAIL: " + $_.Exception.Message) }
    } else { Say "  Needs admin. Skipped." }

    Say ""
    Say "Done. Re-test with:  .\wifi_hotspot_tool.ps1 -Baseline"
    Say "If a change needs the adapter reloaded: disable/enable WLAN in Device Manager, or reboot."
}

# ------------------------------------------------------------------ RESET
# For the case where TWO different phones both fail: the problem is on this PC.
if ($Reset) {
    Head "R1. Unbind VMware Bridge Protocol from WLAN"
    if ($isAdmin) {
        $b = Get-NetAdapterBinding -Name WLAN -ComponentID vmware_bridge -ErrorAction SilentlyContinue
        if ($b) {
            Say ("  Before: enabled=" + $b.Enabled)
            try {
                Disable-NetAdapterBinding -Name WLAN -ComponentID vmware_bridge -ErrorAction Stop
                $a = Get-NetAdapterBinding -Name WLAN -ComponentID vmware_bridge -ErrorAction SilentlyContinue
                Say ("  After : enabled=" + $a.Enabled)
                Say "  (Wi-Fi bridging for VMs is unsupported anyway; re-enable with Enable-NetAdapterBinding if needed.)"
            } catch { Say ("  FAIL: " + $_.Exception.Message) }
        } else { Say "  vmware_bridge not bound to WLAN. Nothing to do." }
    } else { Say "  Needs admin. Skipped." }

    Head "R2. Reset Winsock and TCP/IP stacks"
    if ($isAdmin) {
        Say "  netsh winsock reset:"
        (netsh winsock reset 2>&1) | ForEach-Object { Say ("    " + $_) }
        Say "  netsh int ip reset:"
        (netsh int ip reset 2>&1) | ForEach-Object { Say ("    " + $_) }
        Say "  ipconfig /flushdns:"
        (ipconfig /flushdns 2>&1) | ForEach-Object { Say ("    " + $_) }
        Say "  >> A reboot is required for winsock/ip reset to take effect."
    } else { Say "  Needs admin. Skipped." }

    Head "R3. Restart the WLAN adapter (reload driver state)"
    if ($isAdmin) {
        try {
            Disable-NetAdapter -Name WLAN -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 3
            Enable-NetAdapter -Name WLAN -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 5
            $s = Get-NetAdapter -Name WLAN
            Say ("  Adapter now: " + $s.Status)
        } catch { Say ("  FAIL: " + $_.Exception.Message) }
    } else { Say "  Needs admin. Skipped." }

    Say ""
    Say "NEXT: reboot the PC, then connect to a phone hotspot and test with -Hotspot."
}

# ----------------------------------------------------------------- REPORT
if ($Report) {
    Head "10. Windows wlanreport"
    if ($isAdmin) {
        netsh wlan show wlanreport 2>&1 | ForEach-Object { Say $_ }
        $rep = "C:\ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html"
        if (Test-Path $rep) {
            Say ("  Report: " + $rep)
            Start-Process $rep
        }
    } else { Say "  Needs admin. Open an elevated PowerShell and re-run with -Report" }
}

# ----------------------------------------------------------------- FORGET
if ($Forget) {
    Head ("11. Delete Wi-Fi profile: " + $Forget)
    if ($isAdmin) {
        netsh wlan delete profile name="$Forget" 2>&1 | ForEach-Object { Say $_ }
        Say "  Deleted. Reconnect from the Wi-Fi list when needed."
    } else { Say "  Needs admin. Skipped." }
}

Say ""
Say ("Log saved to: " + $script:LogPath)
