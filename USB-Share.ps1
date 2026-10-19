# USB Share - iPhone USB reverse tethering on Windows.
#
#   USB-Share.ps1              plug-and-go (auto) - default
#   USB-Share.ps1 menu         interactive menu
#   USB-Share.ps1 on|off       switch the share
#   USB-Share.ps1 status       device / mode / adapter / share / lease
#   USB-Share.ps1 watch        live link counters until Ctrl+C
#   USB-Share.ps1 auto         plug-and-go: wait for phone, share, watch, re-arm on unplug
#   add -Verbose for raw tool output
#
# Sequence for ON (each step is printed):
#   1. usbccgp index 2, restart device  -> phone back in initial USB mode (GET_MODE 3:3:3:0)
#   2. usbccgp index 4, SET_MODE 3      -> phone re-enumerates with a CDC-NCM function, UsbNcm binds
#   3. ICS Wi-Fi -> that adapter        -> DHCP/NAT on 192.168.137.0/24, phone leases an address
# OFF removes the share and restores index 2 so a replug never fails to start.
# One-time prerequisites are listed in README.md.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('on', 'off', 'status', 'watch', 'auto', 'menu')][string]$Command = 'auto'
)
$ErrorActionPreference = 'Stop'
$script:ShowDebug = ($VerbosePreference -eq 'Continue')
$VerbosePreference = 'SilentlyContinue'   # keep module auto-load chatter out of -Verbose output
$Host.UI.RawUI.WindowTitle = 'USB Share'

# Fail fast on missing prerequisites - before touching the phone.
$missing = @()
foreach ($f in 'iphone_mode.py', 'libusb0.dll') { if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { $missing += "$f (must sit next to this script in $PSScriptRoot)" } }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { $missing += 'python (Python 3 on PATH)' }
else { $null = & python -c 'import usb.core' 2>&1; if ($LASTEXITCODE -ne 0) { $missing += 'pyusb (pip install pyusb)' } }
if (-not (Get-Service libusb0 -ErrorAction SilentlyContinue)) { $missing += 'libusb-win32 filter driver (see README, one-time setup)' }
if ($missing) {
    Write-Host ''
    Write-Host '  USB Share cannot run - missing:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host ''
    if (-not [Console]::IsInputRedirected) { Write-Host 'Press any key to close...'; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    exit 1
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Command" + $(if ($script:ShowDebug) { ' -Verbose' } else { '' })
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine
    exit
}

# ---------------------------------------------------------------------------------------------
# Only one copy may drive the phone at a time (two copies fight over the filter handle and the config index).
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Global\USBShare-iPhone', [ref]$created)
if (-not $created -and $Command -ne 'status') {
    Write-Host ''
    Write-Host '  Another USB Share window is already running. Close it first (or use that one).' -ForegroundColor Yellow
    Write-Host ''
    if (-not [Console]::IsInputRedirected) { Write-Host 'Press any key to close...'; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    exit 1
}

$ModeTool  = Join-Path $PSScriptRoot 'iphone_mode.py'
$SafeIndex = 2   # config 3 in initial mode: PTP + usbmux
$NcmIndex  = 4   # config 5 after switch:    PTP + usbmux + CDC-NCM (+ Apple aux NCM)
$Subnet    = '192.168.137.'

function Log([string]$level, [string]$msg) {
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    $color = switch ($level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } 'STEP' { 'Cyan' } 'DBG' { 'DarkGray' } default { 'Gray' } }
    if ($level -ne 'DBG' -or $script:ShowDebug) { Write-Host ("[{0}] {1,-4} {2}" -f $ts, $level, $msg) -ForegroundColor $color }
}
function Fail([string]$msg) { throw $msg }

function Get-Phone { Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^USB\\VID_05AC&PID_12A[0-9A-F]\\[^&]+$' } | Select-Object -First 1 }
function Get-PhoneAdapter { Get-NetAdapter | Where-Object { $_.PnPDeviceID -like 'USB\VID_05AC&PID_12A*&CDC_0D&MI_02\*' -and $_.Status -ne 'Not Present' } | Select-Object -First 1 }
# Windows' photo-import (WPD/PTP) driver opens a session on the phone, which makes iOS show
# "Trust This Computer?" and re-enumerate USB after the answer - that resets the mode mid-sequence.
# Nothing here needs PTP, so keep that interface disabled. (Re-enable in Device Manager for photo import.)
function Disable-PhotoInterface {
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_05AC&PID_12A*MI_00\*' -and $_.Class -eq 'WPD' -and $_.Status -eq 'OK' } | ForEach-Object {
        pnputil /disable-device "$($_.InstanceId)" | Out-Null
        Log INFO 'photo-import (PTP) interface disabled to prevent the Trust prompt'
    }
}
function Get-PhoneNcmFunctions($phoneId) {
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "$($phoneId.Split('\')[0])\$($phoneId.Split('\')[1])&*CDC_0D*" -or ($_.InstanceId -like 'USB\VID_05AC&PID_12A*&MI_*' -and $_.Class -eq 'Net') }
}
function Get-ConfigIndex($phoneId) { Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$phoneId\Device Parameters" | Select-Object OriginalConfigurationValue, AltConfigurationValue }
function Set-ConfigIndex($phoneId, $orig, $alt) {
    $hk = "HKLM:\SYSTEM\CurrentControlSet\Enum\$phoneId\Device Parameters"
    Set-ItemProperty $hk OriginalConfigurationValue $orig -Type DWord
    Set-ItemProperty $hk AltConfigurationValue $alt -Type DWord
    Log DBG "usbccgp OriginalConfigurationValue=$orig AltConfigurationValue=$alt"
}
function Invoke-ModeTool([string[]]$argv) {
    $out = & python $ModeTool @argv 2>&1
    foreach ($l in $out) { Log DBG "iphone_mode: $l" }
    $mode = ($out | Select-String 'GET_MODE (\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
    return @{ rc = $LASTEXITCODE; mode = $mode; out = $out }
}
# The libusb filter is enumerable only a little after the composite device reports OK; poll for it.
function Wait-ModeTool([int]$seconds) {
    for ($i = 0; $i -lt $seconds; $i++) {
        $m = Invoke-ModeTool @('get')
        if ($m.rc -eq 0) { Log DBG "filter reachable after ${i}s"; return $m }
        Start-Sleep 1
    }
    foreach ($l in $m.out) { Log WARN "iphone_mode: $l" }
    return $m
}
# An interrupted disable/enable cycle can leave the composite device disabled; Windows persists that.
function Enable-IfDisabled($dev) {
    if ($dev -and $dev.Problem -eq 'CM_PROB_DISABLED') {
        Log WARN 'phone composite device was left disabled; enabling'
        pnputil /enable-device "$($dev.InstanceId)" | Out-Null
        Wait-Until { (Get-PnpDevice -InstanceId $dev.InstanceId).Status -eq 'OK' } 20 'composite device OK' | Out-Null
    }
}
function Wait-Phone {
    $p = Get-Phone
    if ($p) { Enable-IfDisabled $p; return $p }
    Log INFO 'waiting for an iPhone on USB (data cable; tap Trust if asked)...'
    while (-not $p) { Start-Sleep 2; $p = Get-Phone }
    Log OK "phone detected: $($p.FriendlyName)"
    # let enumeration settle: wait until the device is OK or has a definite error (not mid-start)
    Wait-Until { $d = Get-Phone; $d -and $d.Status -in 'OK', 'Error' } 15 'device settled' | Out-Null
    Start-Sleep 2
    Enable-IfDisabled (Get-Phone)
    return $p
}
function Get-Ics {
    $ics = New-Object -ComObject HNetCfg.HNetShare
    $map = @{}
    foreach ($c in @($ics.EnumEveryConnection)) { $map[$ics.NetConnectionProps($c).Name] = $ics.INetSharingConfigurationForINetConnection($c) }
    return $map
}
function Get-WifiName {
    $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface })
    $interfaces = @{}
    foreach ($ip in @(Get-NetIPInterface -AddressFamily IPv4)) { $interfaces[$ip.InterfaceIndex] = $ip }
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
    $candidates = @(foreach ($route in $routes) {
        $adapter = $adapters | Where-Object { $_.ifIndex -eq $route.InterfaceIndex } | Select-Object -First 1
        $ip = $interfaces[$route.InterfaceIndex]
        if ($adapter -and $ip -and $ip.ConnectionState -eq 'Connected') {
            [pscustomobject]@{
                Name = $adapter.Name
                Metric = [long]$route.RouteMetric + [long]$ip.InterfaceMetric
                InterfaceIndex = $route.InterfaceIndex
            }
        }
    })
    ($candidates | Sort-Object Metric, InterfaceIndex | Select-Object -First 1).Name
}
function Get-Lease($alias) {
    Get-NetNeighbor -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$Subnet*" -and $_.IPAddress -ne "${Subnet}255" -and $_.IPAddress -ne "${Subnet}1" -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } |
        Select-Object -First 1
}
function Wait-Until([scriptblock]$cond, [int]$seconds, [string]$what) {
    for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { Log DBG "$what after ${i}s"; return $true }; Start-Sleep 1 }
    Log WARN "timeout after ${seconds}s waiting for $what"
    return $false
}
function Stop-MobileHotspotIfOn {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
    $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $profile) { Fail 'Laptop has no internet connection to share.' }
    $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
    if ($mgr.TetheringOperationalState -eq 'On') {
        $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        $t = $asTask.MakeGenericMethod([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]).Invoke($null, @($mgr.StopTetheringAsync())); $t.Wait(-1) | Out-Null
        Log WARN 'Mobile Hotspot was on; stopped it (it shares the same service as ICS)'
    }
    return $profile.ProfileName
}

# ---------------------------------------------------------------------------------------------
function Get-State {
    $phone = Get-Phone
    $adapter = Get-PhoneAdapter
    $ics = Get-Ics
    [pscustomobject]@{
        Phone   = $phone
        Adapter = $adapter
        Ics     = $ics
        ShareOn = [bool]($adapter -and $ics.ContainsKey($adapter.Name) -and $ics[$adapter.Name].SharingEnabled)
        Lease   = $(if ($adapter) { Get-Lease $adapter.Name } else { $null })
    }
}

function Show-Status {
    $s = Get-State
    Write-Host ''
    Write-Host '  USB Share status' -ForegroundColor White
    Write-Host '  ----------------'
    if (-not $s.Phone) { Write-Host '  Phone    : not connected' -ForegroundColor Red; return $s }
    $idx = Get-ConfigIndex $s.Phone.InstanceId
    Write-Host "  Phone    : $($s.Phone.FriendlyName) [$($s.Phone.Status)]  usbccgp index=$($idx.OriginalConfigurationValue)/$($idx.AltConfigurationValue)"
    $m = Wait-ModeTool 3
    $modeText = switch ($m.mode) { '3:3:3:0' { 'initial (no NCM)' } '5:3:3:0' { 'switched (CDC-NCM exposed)' } default { "unknown ($($m.mode))" } }
    Write-Host "  USB mode : $(if ($m.rc -eq 0) { $modeText } else { 'unreachable through libusb filter' })"
    $ncm = Get-PhoneNcmFunctions $s.Phone.InstanceId
    foreach ($f in $ncm) { Write-Host "  NCM func : $($f.InstanceId.Split('\')[1]) [$($f.Status)$(if ($f.Problem -ne 'CM_PROB_NONE') { ' ' + $f.Problem })]" }
    if ($s.Adapter) {
        $st = Get-NetAdapterStatistics -Name $s.Adapter.Name -ErrorAction SilentlyContinue
        Write-Host "  Adapter  : $($s.Adapter.Name) [$($s.Adapter.Status)] mac=$($s.Adapter.MacAddress) rx=$($st.ReceivedBytes) tx=$($st.SentBytes)"
    } else { Write-Host '  Adapter  : none' }
    Write-Host "  Share    : $(if ($s.ShareOn) { 'ON  (Wi-Fi -> ' + $s.Adapter.Name + ', laptop ' + $Subnet + '1)' } else { 'OFF' })" -ForegroundColor $(if ($s.ShareOn) { 'Green' } else { 'Yellow' })
    Write-Host "  Lease    : $(if ($s.Lease) { $s.Lease.IPAddress + ' (' + $s.Lease.LinkLayerAddress + ', ' + $s.Lease.State + ')' } else { 'none' })"
    Write-Host ''
    return $s
}

function Start-Share {
    $null = Wait-Phone
    $s = Get-State
    if ($s.ShareOn) { Log OK "share already ON via $($s.Adapter.Name)"; return }
    $phoneId = $s.Phone.InstanceId
    $script:LastPhoneId = $phoneId
    Log INFO "phone: $($s.Phone.FriendlyName) [$($s.Phone.Status)$(if ($s.Phone.Problem -ne 'CM_PROB_NONE') { ' ' + $s.Phone.Problem })] $phoneId"
    Disable-PhotoInterface
    $uplink = Stop-MobileHotspotIfOn
    $wifi = Get-WifiName
    if (-not $wifi) { Fail 'No connected Ethernet or Wi-Fi adapter with an IPv4 default route to share.' }
    Log INFO "uplink: $wifi ($uplink)"

    $adapter = $s.Adapter
    if ($adapter -and $adapter.Status -eq 'Up') {
        Log OK "phone already in NCM mode, adapter $($adapter.Name) is up - skipping steps 1-2"
    }
    else {
        Log STEP '1/3 reset phone to initial USB mode'
        Set-ConfigIndex $phoneId $SafeIndex 0
        pnputil /restart-device "$phoneId" | Out-Null
        if (-not (Wait-Until { (Get-PnpDevice -InstanceId $phoneId).Status -eq 'OK' } 20 'composite device OK')) {
            $d = Get-PnpDevice -InstanceId $phoneId
            Log WARN "device still $($d.Status) ($($d.Problem)); disable/enable cycle"
            pnputil /disable-device "$phoneId" | Out-Null; Start-Sleep 3; pnputil /enable-device "$phoneId" | Out-Null
            if (-not (Wait-Until { (Get-PnpDevice -InstanceId $phoneId).Status -eq 'OK' } 25 'composite device OK')) {
                $d = Get-PnpDevice -InstanceId $phoneId
                Fail "phone composite device did not start ($($d.Status) $($d.Problem)) - unplug, wait 5s, replug"
            }
        }
        # children (incl. the PTP interface) appear a few seconds after the composite reports OK
        Wait-Until { Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\VID_05AC&PID_12A*MI_00\*' } } 10 'PTP child present' | Out-Null
        Disable-PhotoInterface
        $m = Wait-ModeTool 15
        if ($m.rc -ne 0) {
            Log WARN 'filter not reachable yet; cycling the device once more'
            pnputil /disable-device "$phoneId" | Out-Null; Start-Sleep 2; pnputil /enable-device "$phoneId" | Out-Null
            Wait-Until { (Get-PnpDevice -InstanceId $phoneId).Status -eq 'OK' } 20 'composite device OK' | Out-Null
            $m = Wait-ModeTool 15
        }
        if ($m.rc -ne 0) { Fail 'cannot reach the phone through the libusb filter - unplug, replug, try again (if it persists: one-time setup, see README)' }
        Log INFO "GET_MODE $($m.mode)"
        if ($m.mode -ne '3:3:3:0') { Log WARN "unexpected mode $($m.mode); trying the switch anyway" }

        Log STEP '2/3 switch phone to CDC-NCM (SET_MODE 3)'
        Set-ConfigIndex $phoneId $NcmIndex $SafeIndex
        $m = Invoke-ModeTool @('set', '3')
        if ($m.rc -ne 0) { Set-ConfigIndex $phoneId $SafeIndex 0; Fail 'phone rejected the mode switch - unplug, replug, run again' }
        Log OK 'switch accepted, phone is re-enumerating'
        # A previous interrupted run can leave the NCM function disabled; Windows persists that per instance.
        Wait-Until { (Get-PhoneNcmFunctions $phoneId | Where-Object { $_.InstanceId -like '*CDC_0D&MI_02*' }) } 15 'NCM function present' | Out-Null
        Get-PhoneNcmFunctions $phoneId | Where-Object { $_.Problem -eq 'CM_PROB_DISABLED' } | ForEach-Object {
            Log WARN "NCM function $($_.InstanceId.Split('\')[1]) was disabled; enabling"
            pnputil /enable-device "$($_.InstanceId)" | Out-Null
        }
        if (-not (Wait-Until { $a = Get-PhoneAdapter; $a -and $a.Status -eq 'Up' } 30 'NCM adapter up')) {
            $ncm = Get-PhoneNcmFunctions $phoneId
            foreach ($f in $ncm) { Log WARN "NCM function $($f.InstanceId.Split('\')[1]): $($f.Status) $($f.Problem)" }
            Set-ConfigIndex $phoneId $SafeIndex 0
            Fail 'USB Ethernet adapter did not come up - unplug, replug, run again'
        }
        $adapter = Get-PhoneAdapter
        Log OK "adapter $($adapter.Name) up, mac $($adapter.MacAddress)"
        Disable-PhotoInterface   # PTP interface has a new instance id in the NCM configuration
        Start-Sleep 3
    }

    Log STEP "3/3 share $wifi -> $($adapter.Name)"
    $ics = Get-Ics
    foreach ($k in $ics.Keys) { if ($ics[$k].SharingEnabled) { Log DBG "clearing old ICS on $k"; $ics[$k].DisableSharing() } }
    if (-not $ics.ContainsKey($wifi)) { Fail "ICS does not list $wifi" }
    if (-not $ics.ContainsKey($adapter.Name)) { Fail "ICS does not list $($adapter.Name) yet - wait a few seconds and retry" }
    $ics[$wifi].EnableSharing(0);          Log DBG "ICS public: $wifi"
    $ics[$adapter.Name].EnableSharing(1);  Log DBG "ICS private: $($adapter.Name)"
    Log INFO 'bouncing link so the phone re-runs DHCP'
    try {
        Restart-NetAdapter -Name $adapter.Name -Confirm:$false
    }
    catch {
        if (-not (Get-PhoneAdapter)) { Fail 'phone re-enumerated during setup (Trust prompt answered?) - retrying' }
        Log WARN "link bounce failed: $($_.Exception.Message)"
    }
    Wait-Until { [bool](Get-Lease $adapter.Name) } 30 'DHCP lease' | Out-Null
    $lease = Get-Lease $adapter.Name

    Write-Host ''
    Log OK 'USB SHARE ON'
    Log INFO "internet : $wifi ($uplink)"
    Log INFO "phone    : $($adapter.Name), laptop side ${Subnet}1"
    if ($lease) { Log OK "lease    : $($lease.IPAddress) ($($lease.LinkLayerAddress))" } else { Log WARN 'lease    : not seen yet - check Settings > Ethernet on the phone, or run: status' }
    Log INFO 'nothing wireless is emitted by the laptop for this link'
}

function Stop-Share {
    $s = Get-State
    if (-not $s.ShareOn) { Log INFO 'share already OFF' }
    else {
        foreach ($k in $s.Ics.Keys) { if ($s.Ics[$k].SharingEnabled) { Log DBG "disabling ICS on $k"; $s.Ics[$k].DisableSharing() } }
        Log OK 'USB SHARE OFF'
    }
    if ($s.Phone) { Set-ConfigIndex $s.Phone.InstanceId $SafeIndex 0; Log INFO 'usbccgp index restored to safe value (replug-proof)' }
    Log INFO 'phone stays in NCM mode until unplugged; harmless'
}

function Watch-Share([switch]$UntilGone) {
    $s = Get-State
    if (-not $s.Adapter) { Fail 'no phone adapter to watch' }
    $name = $s.Adapter.Name
    Log INFO "watching $name every 2s - $(if ($UntilGone) { 'returns when the phone is unplugged' } else { 'Ctrl+C to stop' })"
    $prev = Get-NetAdapterStatistics -Name $name -ErrorAction SilentlyContinue
    while ($true) {
        Start-Sleep 2
        $cur = Get-NetAdapterStatistics -Name $name -ErrorAction SilentlyContinue
        if (-not $cur -or -not (Get-Phone)) { Log WARN 'phone link gone'; return }
        $lease = Get-Lease $name
        $rx = [math]::Round(($cur.ReceivedBytes - $prev.ReceivedBytes) / 2KB, 1)
        $tx = [math]::Round(($cur.SentBytes - $prev.SentBytes) / 2KB, 1)
        $line = '[{0}] {1,-10} rx {2,8} KB/s  tx {3,8} KB/s  total rx {4} MB tx {5} MB  phone {6}' -f @(
            (Get-Date -Format 'HH:mm:ss'), (Get-NetAdapter -Name $name -ErrorAction SilentlyContinue).Status, $rx, $tx,
            [math]::Round($cur.ReceivedBytes / 1MB, 1), [math]::Round($cur.SentBytes / 1MB, 1),
            $(if ($lease) { $lease.IPAddress } else { '-' }))
        Write-Host $line
        $prev = $cur
    }
}

# Plug-and-go: wait for phone -> share on -> live counters -> on unplug, clean up and wait again.
function Start-Auto {
    Log INFO 'auto mode - Ctrl+C to stop'
    $failures = 0
    while ($true) {
        try {
            $null = Wait-Phone
            Start-Share
            $failures = 0
            Watch-Share -UntilGone
        }
        catch { Log ERR $_.Exception.Message; $failures++ }
        try { (Get-Ics).Values | Where-Object { $_.SharingEnabled } | ForEach-Object { $_.DisableSharing() } } catch { }
        if ($script:LastPhoneId) { try { Set-ConfigIndex $script:LastPhoneId $SafeIndex 0 } catch { } }
        if ((Get-Phone) -and $failures -gt 0 -and $failures -le 3) {
            Log WARN "phone still connected; retrying in 5s (attempt $($failures + 1)/4)"
            Start-Sleep 5
            continue
        }
        Log INFO 'share cleared, safe config restored; waiting for the phone to come back'
        while (Get-Phone) { Start-Sleep 2 }   # wait for a real unplug before re-arming
        $failures = 0
    }
}

function Show-Menu {
    while ($true) {
        $s = Show-Status
        Write-Host '  [1] turn ON    [2] turn OFF    [3] watch traffic    [4] auto (plug-and-go)    [r] refresh    [q] quit'
        $k = Read-Host '  >'
        try {
            switch ($k.Trim().ToLower()) {
                '1' { Start-Share }
                '2' { Stop-Share }
                '3' { Watch-Share }
                '4' { Start-Auto }
                'r' { }
                'q' { return }
                default { }
            }
        }
        catch { Log ERR $_.Exception.Message }
        Write-Host ''
    }
}

# ---------------------------------------------------------------------------------------------
Log DBG "---- USB Share start: command=$Command"
try {
    switch ($Command) {
        'on'     { Start-Share }
        'off'    { Stop-Share }
        'status' { Show-Status | Out-Null }
        'watch'  { Watch-Share }
        'auto'   { Start-Auto }
        'menu'   { Show-Menu }
    }
}
catch {
    Log ERR $_.Exception.Message
    if ($script:ShowDebug) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
}
if ($Command -ne 'menu' -and -not [Console]::IsInputRedirected -and $Command -ne 'status') {
    Write-Host ''
    Write-Host 'Press any key to close...'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
