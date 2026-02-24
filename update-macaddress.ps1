$line_delimiter = "---------------"

function select-adapter {
    param($adapters)
    $idx = $null
    while ($true) {
        $choice = (Read-Host "`n请输入要选择的适配器序号").Trim()
        if ($choice -eq "") { continue }
        elseif ($choice -notmatch '^\d+$') {
            Write-Host "输入不合法,请输入整数!"
            continue
        }
        $idx = [int]$choice
        if ($idx -lt 0 -or $idx -ge $adapters.Count) {
            Write-Host "超出有效范围 (0 .. $($adapters.Count - 1))"
            $idx = $null
            continue
        }
        else {
            $props = Get-ItemProperty $adapters[$idx].PSPath
            $desc = $props.DriverDesc
            Write-Host "已选中适配器："
            Write-Host $line_delimiter
            Write-Host "$idx`: $desc"
            Write-Host $line_delimiter
            break
        }
    }
    return $idx
}

# 获取物理网卡对应的注册表项
$adapters = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue |
Where-Object {
    $v = (Get-ItemProperty $_.PSPath).DeviceInstanceID
    $v -match '^(PCI\\VEN_|USB\\VID_)'
}

if ($null -eq $adapters) {
    Write-Host "未找到有效的网络适配器注册表项。"
    exit
}

Write-Host "找到以下网络适配器："
Write-Host $line_delimiter
for ($i = 0; $i -lt $adapters.Count; $i++) {
    $props = Get-ItemProperty $adapters[$i].PSPath
    Write-Host "$i`: $($props.DriverDesc)"
}
Write-Host $line_delimiter

$idx = select-adapter $adapters
$path = $adapters[$idx].PSPath
$props = Get-ItemProperty $path

# 获取当前注册表值
$current = $props.NetworkAddress
$id = $props.NetCfgInstanceId

# 逻辑核心：如果注册表不存在或格式错误，则从系统 API 获取硬件 MAC
if ([string]::IsNullOrWhiteSpace($current) -or $current -notmatch '^[0-9A-Fa-f]{12}$') {
    Write-Host "注册表 NetworkAddress 不存在或无效，正在获取硬件原始 MAC..."
    $hwAdapter = Get-NetAdapter | Where-Object { $_.InterfaceGuid -eq $id }
    # 移除硬件地址中的连字符以符合注册表格式 (如 00-11... -> 0011...)
    $current = $hwAdapter.PermanentAddress -replace '-', ''
}

if ([string]::IsNullOrWhiteSpace($current)) {
    Write-Host "错误：无法获取该网卡的物理 MAC 地址。"
    Read-Host "按下 ENTER 退出..."
    exit
}

Write-Host "基准 MAC 地址: $current"
Write-Host "输入 + 或 - 来修改 MAC 地址"

# 转换成 64 位整数处理
$macInt = [Convert]::ToInt64($current, 16)

while ($true) {
    $choice = Read-Host 
    if ($choice -eq "+") {
        $macInt++
        break
    }
    elseif ($choice -eq "-") {
        $macInt--
        break
    }
    else {
        Write-Host "输入无效，请输入 + 或 - !"
    }
}

# 格式化为 12 位十六进制
$newMac = "{0:X12}" -f $macInt

# 写入注册表（若不存在则自动创建，若存在则更新）
try {
    Set-ItemProperty -Path $path -Name "NetworkAddress" -Value $newMac -Force
    Write-Host "成功写入注册表: $newMac"
}
catch {
    Write-Host "权限不足或写入失败: $_"
    exit
}

# 重启网卡以应用更改
$adapter = Get-NetAdapter | Where-Object { $_.InterfaceGuid -eq $id } | Select-Object -First 1
$adapterName = $adapter.Name

Write-Host "正在重启网卡: $adapterName ..."
Disable-NetAdapter -Name $adapterName -Confirm:$false
do { Start-Sleep -Milliseconds 200 } until ((Get-NetAdapter -Name $adapterName).Status -eq 'Disabled')

Enable-NetAdapter -Name $adapterName -Confirm:$false
do { Start-Sleep -Milliseconds 200 } until ((Get-NetAdapter -Name $adapterName).Status -ne 'Disabled')

Write-Host "操作完成。"
Read-Host "按下 ENTER 退出..."
