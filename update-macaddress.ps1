# -----------------------------------------------
# MAC 地址修改工具 (加固版)
# 功能：自动请求管理员权限、修改指定网卡 MAC 地址
# -----------------------------------------------

#region ── 常量 ──────────────────────────────────────────────────────────────
$SCRIPT_URL    = "https://sisyphite.github.io/awesomescripts/update-macaddress.ps1"
$REG_BASE      = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
$LINE          = "---------------"
$MAC_MAX       = 0xFFFFFFFFFFFFL   # 用 L 后缀强制 [long]，避免溢出到负数
$ADAPTER_TIMEOUT_MS = 15000
#endregion

#region ── 自动提权 ───────────────────────────────────────────────────────────
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-Admin)) {
    Write-Host "权限不足，正在以管理员身份重新启动脚本..."

    $scriptPath = $MyInvocation.MyCommand.Definition
    $tmpFile    = $null

    # irm | iex 管道执行时，Definition 是宿主 exe 路径，需要落盘后再提权
    if ($scriptPath -notlike "*.ps1") {
        $tmpFile = Join-Path $env:TEMP ("update_mac_{0}.ps1" -f [System.IO.Path]::GetRandomFileName())
        try {
            $src = Invoke-RestMethod -Uri $SCRIPT_URL -UseBasicParsing -ErrorAction Stop
            # 验证下载内容是否像一个 PowerShell 脚本（防止下载到错误页面）
            if ($src -notmatch '#.*MAC') {
                throw "下载内容校验失败，可能获取到了错误的页面。"
            }
            Set-Content -Path $tmpFile -Value $src -Encoding UTF8 -Force
            $scriptPath = $tmpFile
        }
        catch {
            Write-Host "错误：无法获取脚本内容以提权重启。`n  $_"
            Write-Host "请手动以管理员身份运行此脚本。"
            Read-Host "按下 ENTER 退出..."
            exit 1
        }
    }

    try {
        # -Wait 确保临时文件在子进程退出前不会被删除
        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -ErrorAction Stop
        # 透传子进程退出码
        $exitCode = if ($proc) { $proc.ExitCode } else { 0 }
    }
    catch {
        Write-Host "错误：无法获取管理员权限。`n  $_"
        Write-Host "请手动以管理员身份运行此脚本。"
        $exitCode = 1
    }
    finally {
        # 子进程已退出，现在可以安全删除临时文件
        if ($tmpFile -and (Test-Path $tmpFile)) {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }

    exit $exitCode
}
#endregion

#region ── 辅助函数 ───────────────────────────────────────────────────────────

# 从注册表或 PermanentAddress 获取 12 位十六进制基准 MAC
function Get-BaseMAC {
    param(
        [string]$RegPath,
        [string]$NetCfgInstanceId
    )

    $current = (Get-ItemProperty $RegPath -ErrorAction SilentlyContinue).NetworkAddress

    # 注册表值存在且合法则直接用
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $clean = $current -replace '[-:]', ''
        if ($clean -match '^[0-9A-Fa-f]{12}$') {
            return $clean.ToUpper()
        }
    }

    Write-Host "注册表 NetworkAddress 不存在或无效，正在读取硬件原始 MAC..."

    $hwAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                 Where-Object { $_.InterfaceGuid -eq $NetCfgInstanceId } |
                 Select-Object -First 1

    if ($null -eq $hwAdapter) {
        Write-Host "错误：无法通过 InterfaceGuid 找到对应网卡。"
        return $null
    }

    $perm = $hwAdapter.PermanentAddress -replace '[-:]', ''

    if ($perm -notmatch '^[0-9A-Fa-f]{12}$') {
        Write-Host "错误：PermanentAddress 格式异常: '$($hwAdapter.PermanentAddress)'"
        return $null
    }

    # 全零地址视为无效（某些驱动占位符）
    if ($perm -eq '000000000000') {
        Write-Host "错误：PermanentAddress 全零，驱动可能不支持读取物理地址。"
        return $null
    }

    return $perm.ToUpper()
}

# 等待网卡达到目标状态，超时返回 $false
function Wait-AdapterStatus {
    param(
        [string]$Name,
        [string]$TargetStatus,   # 'Disabled' 或非 'Disabled'
        [int]   $TimeoutMs = $ADAPTER_TIMEOUT_MS
    )

    $elapsed  = 0
    $interval = 300

    while ($elapsed -lt $TimeoutMs) {
        Start-Sleep -Milliseconds $interval
        $elapsed += $interval
        $status = (Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue).Status

        $reached = if ($TargetStatus -eq 'Disabled') {
            $status -eq 'Disabled'
        } else {
            $status -ne 'Disabled' -and -not [string]::IsNullOrEmpty($status)
        }

        if ($reached) { return $true }
    }
    return $false
}

function Restart-NetworkAdapter {
    param([string]$AdapterName)

    Write-Host "正在重启网卡: $AdapterName ..."

    try {
        Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
    }
    catch {
        throw "禁用网卡失败: $_"
    }

    if (-not (Wait-AdapterStatus -Name $AdapterName -TargetStatus 'Disabled')) {
        Write-Host "警告：等待网卡禁用超时，继续尝试启用..."
    }

    try {
        Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
    }
    catch {
        throw "启用网卡失败: $_"
    }

    if (-not (Wait-AdapterStatus -Name $AdapterName -TargetStatus 'Up')) {
        Write-Host "警告：等待网卡启用超时，请手动确认网卡状态。"
    }
    else {
        Write-Host "网卡已恢复正常。"
    }
}

# 显示已枚举适配器并让用户选择
function Select-Adapter {
    param([array]$Adapters)

    while ($true) {
        $choice = (Read-Host "`n请输入要选择的适配器序号").Trim()

        if ([string]::IsNullOrEmpty($choice)) { continue }

        if ($choice -notmatch '^\d+$') {
            Write-Host "输入不合法，请输入整数！"
            continue
        }

        $idx = [int]$choice

        if ($idx -lt 0 -or $idx -ge $Adapters.Count) {
            Write-Host "超出有效范围 (0 .. $($Adapters.Count - 1))"
            continue
        }

        $desc = (Get-ItemProperty $Adapters[$idx].PSPath -ErrorAction SilentlyContinue).DriverDesc
        Write-Host "已选中适配器："
        Write-Host $LINE
        Write-Host "${idx}: $desc"
        Write-Host $LINE
        return $idx
    }
}

# 验证 MAC 字节1 的合法性（单播 + 全球管理地址）
function Test-MACValid {
    param([long]$MacInt)
    # 取最高字节（字节 0）：低位第1位=组播位，低位第2位=本地管理位
    # 新 MAC 应为单播（bit0=0）；本地管理（bit1=1）是可接受的
    $byte0 = ($MacInt -shr 40) -band 0xFF
    if ($byte0 -band 0x01) {
        Write-Host "警告：生成的 MAC 地址第一个字节为奇数（组播地址），已自动将组播位清零。"
        return $MacInt -band (-bnot (0x01L -shl 40))
    }
    return $MacInt
}
#endregion

#region ── 枚举适配器 ─────────────────────────────────────────────────────────
$adapters = Get-ChildItem $REG_BASE -ErrorAction SilentlyContinue | Where-Object {
    $devId = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DeviceInstanceID
    $devId -match '^(PCI\\VEN_|USB\\VID_)'
}

if (-not $adapters -or $adapters.Count -eq 0) {
    Write-Host "错误：未找到有效的网络适配器注册表项（PCI/USB）。"
    Read-Host "按下 ENTER 退出..."
    exit 1
}

Write-Host "找到以下网络适配器："
Write-Host $LINE
for ($i = 0; $i -lt $adapters.Count; $i++) {
    $desc = (Get-ItemProperty $adapters[$i].PSPath -ErrorAction SilentlyContinue).DriverDesc
    Write-Host "${i}: $desc"
}
Write-Host $LINE
#endregion

#region ── 主流程 ─────────────────────────────────────────────────────────────
$idx  = Select-Adapter $adapters
$path = $adapters[$idx].PSPath
$id   = (Get-ItemProperty $path -ErrorAction SilentlyContinue).NetCfgInstanceId

if ([string]::IsNullOrWhiteSpace($id)) {
    Write-Host "错误：无法读取 NetCfgInstanceId，注册表项可能已损坏。"
    Read-Host "按下 ENTER 退出..."
    exit 1
}

$current = Get-BaseMAC -RegPath $path -NetCfgInstanceId $id

if ([string]::IsNullOrWhiteSpace($current)) {
    Write-Host "错误：无法获取该网卡的物理 MAC 地址，终止操作。"
    Read-Host "按下 ENTER 退出..."
    exit 1
}

Write-Host "基准 MAC 地址: $current"
Write-Host "输入 + 或 - 来修改 MAC 地址（偏移量 ±1）"

# 用 [long] 确保全程有符号 64 位运算，不会静默截断
[long]$macInt = [Convert]::ToInt64($current, 16)

while ($true) {
    $choice = (Read-Host).Trim()
    if     ($choice -eq '+') { $macInt++; break }
    elseif ($choice -eq '-') { $macInt--; break }
    else   { Write-Host "输入无效，请输入 + 或 -！" }
}

# 防溢出夹紧
$macInt = [Math]::Max(0L, [Math]::Min($macInt, $MAC_MAX))

# 检查并修正组播位
$macInt = Test-MACValid -MacInt $macInt

# 格式化为 12 位大写十六进制
$newMac = '{0:X12}' -f $macInt
Write-Host "新 MAC 地址: $newMac"

# 写入注册表
try {
    Set-ItemProperty -Path $path -Name "NetworkAddress" -Value $newMac -Type String -Force -ErrorAction Stop
    Write-Host "成功写入注册表: $newMac"
}
catch {
    Write-Host "写入注册表失败: $_"
    Read-Host "按下 ENTER 退出..."
    exit 1
}

# 重启网卡
$adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceGuid -eq $id } |
           Select-Object -First 1

if ($null -eq $adapter) {
    Write-Host "警告：找不到对应网卡（InterfaceGuid: $id），请手动重启网卡以应用更改。"
}
else {
    try {
        Restart-NetworkAdapter -AdapterName $adapter.Name
    }
    catch {
        Write-Host "重启网卡时出错: $_"
        Write-Host "请手动禁用并重新启用该网卡以应用 MAC 地址更改。"
    }
}

Write-Host "操作完成。"
Read-Host "按下 ENTER 退出..."
exit 0
#endregion
