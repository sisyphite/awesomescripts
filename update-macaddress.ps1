# -----------------------------------------------
# MAC 地址修改工具
# 功能：自动请求管理员权限、修改指定网卡 MAC 地址
# -----------------------------------------------

#region ── 自动提权 ────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "权限不足，正在以管理员身份重新启动脚本..."

    $scriptPath = $MyInvocation.MyCommand.Definition

    # 通过管道（irm | iex）执行时，Definition 返回的是宿主 exe 路径而非 .ps1 文件
    # 用扩展名判断是否真的有落盘脚本
    if ($scriptPath -notlike "*.ps1") {
        $tmpFile = Join-Path $env:TEMP "update_mac_$(Get-Random).ps1"
        try {
            # 从远端重新下载脚本内容写入临时文件
            $src = (Invoke-RestMethod -Uri "https://sisyphite.github.io/awesomescripts/update-macaddress.ps1" -ErrorAction Stop)
            Set-Content -Path $tmpFile -Value $src -Encoding UTF8 -Force
            $scriptPath = $tmpFile
        }
        catch {
            Write-Host "错误：无法获取脚本内容以提权重启。请手动以管理员身份运行此脚本。"
            Read-Host "按下 ENTER 退出..."
            exit
        }
    }

    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -Verb RunAs `
            -ErrorAction Stop
    }
    catch {
        Write-Host "错误：无法获取管理员权限。请手动以管理员身份运行此脚本。"
        Read-Host "按下 ENTER 退出..."
    }
    exit
}
#endregion

$line_delimiter = "---------------"

#region ── 辅助函数 ───────────────────────────────────────────────────────────
function Select-Adapter {
    param([array]$Adapters)

    while ($true) {
        $choice = (Read-Host "`n请输入要选择的适配器序号").Trim()

        if ($choice -eq "") { continue }

        if ($choice -notmatch '^\d+$') {
            Write-Host "输入不合法，请输入整数！"
            continue
        }

        $idx = [int]$choice

        if ($idx -lt 0 -or $idx -ge $Adapters.Count) {
            Write-Host "超出有效范围 (0 .. $($Adapters.Count - 1))"
            continue
        }

        $desc = (Get-ItemProperty $Adapters[$idx].PSPath).DriverDesc
        Write-Host "已选中适配器："
        Write-Host $line_delimiter
        Write-Host "$idx`: $desc"
        Write-Host $line_delimiter
        return $idx
    }
}

function Get-BaseMAC {
    param($RegPath, $NetCfgInstanceId)

    $current = (Get-ItemProperty $RegPath).NetworkAddress

    if ([string]::IsNullOrWhiteSpace($current) -or $current -notmatch '^[0-9A-Fa-f]{12}$') {
        Write-Host "注册表 NetworkAddress 不存在或无效，正在获取硬件原始 MAC..."
        $hwAdapter = Get-NetAdapter | Where-Object { $_.InterfaceGuid -eq $NetCfgInstanceId }

        if ($null -eq $hwAdapter) {
            return $null
        }

        # PermanentAddress 格式可能是 "XX-XX-..." 或 "XXXXXXXXXXXX"，统一去掉分隔符
        $current = $hwAdapter.PermanentAddress -replace '[-:]', ''
    }

    if ($current -notmatch '^[0-9A-Fa-f]{12}$') {
        return $null
    }

    return $current.ToUpper()
}

function Restart-NetworkAdapter {
    param([string]$AdapterName)

    Write-Host "正在重启网卡: $AdapterName ..."

    Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop

    $timeout = 10000   # ms
    $elapsed = 0
    do {
        Start-Sleep -Milliseconds 300
        $elapsed += 300
        $status = (Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue).Status
    } until ($status -eq 'Disabled' -or $elapsed -ge $timeout)

    if ($elapsed -ge $timeout) {
        Write-Host "警告：等待网卡禁用超时，继续尝试启用..."
    }

    Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop

    $elapsed = 0
    do {
        Start-Sleep -Milliseconds 300
        $elapsed += 300
        $status = (Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue).Status
    } until ($status -ne 'Disabled' -or $elapsed -ge $timeout)

    if ($elapsed -ge $timeout) {
        Write-Host "警告：等待网卡启用超时，请手动确认网卡状态。"
    }
    else {
        Write-Host "网卡已恢复正常。"
    }
}
#endregion

#region ── 枚举适配器 ─────────────────────────────────────────────────────────
$regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"

$adapters = Get-ChildItem $regBase -ErrorAction SilentlyContinue | Where-Object {
    $devId = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DeviceInstanceID
    $devId -match '^(PCI\\VEN_|USB\\VID_)'
}

if (-not $adapters -or $adapters.Count -eq 0) {
    Write-Host "未找到有效的网络适配器注册表项。"
    Read-Host "按下 ENTER 退出..."
    exit
}

Write-Host "找到以下网络适配器："
Write-Host $line_delimiter
for ($i = 0; $i -lt $adapters.Count; $i++) {
    $desc = (Get-ItemProperty $adapters[$i].PSPath -ErrorAction SilentlyContinue).DriverDesc
    Write-Host "$i`: $desc"
}
Write-Host $line_delimiter
#endregion

#region ── 主流程 ─────────────────────────────────────────────────────────────
$idx  = Select-Adapter $adapters
$path = $adapters[$idx].PSPath
$id   = (Get-ItemProperty $path).NetCfgInstanceId

$current = Get-BaseMAC -RegPath $path -NetCfgInstanceId $id

if ([string]::IsNullOrWhiteSpace($current)) {
    Write-Host "错误：无法获取该网卡的物理 MAC 地址。"
    Read-Host "按下 ENTER 退出..."
    exit
}

Write-Host "基准 MAC 地址: $current"
Write-Host "输入 + 或 - 来修改 MAC 地址（偏移量 ±1）"

$macInt = [Convert]::ToInt64($current, 16)

while ($true) {
    $choice = (Read-Host).Trim()
    if ($choice -eq "+") { $macInt++; break }
    elseif ($choice -eq "-") { $macInt--; break }
    else { Write-Host "输入无效，请输入 + 或 - ！" }
}

# 防止 MAC 地址溢出（合法范围 0x000000000000 ~ 0xFFFFFFFFFFFF）
$macInt = [Math]::Max(0L, [Math]::Min($macInt, 0xFFFFFFFFFFFFL))

# 格式化为 12 位大写十六进制
$newMac = "{0:X12}" -f $macInt
Write-Host "新 MAC 地址: $newMac"

# 写入注册表
try {
    Set-ItemProperty -Path $path -Name "NetworkAddress" -Value $newMac -Force -ErrorAction Stop
    Write-Host "成功写入注册表: $newMac"
}
catch {
    Write-Host "写入失败: $_"
    Read-Host "按下 ENTER 退出..."
    exit
}

# 重启网卡
$adapter = Get-NetAdapter | Where-Object { $_.InterfaceGuid -eq $id } | Select-Object -First 1

if ($null -eq $adapter) {
    Write-Host "警告：找不到对应网卡，请手动重启网卡以应用更改。"
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
#endregion
