[CmdletBinding()]
param(
    [switch]$SmokeTest
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$coreScript = Join-Path $scriptRoot "AirPodsAutoSwitch.ps1"
& $coreScript -LoadOnly

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$configPath = Join-Path $scriptRoot "AirPodsAutoSwitch.config.json"
$script:Monitoring = $false
$script:Busy = $false
$script:AllowExit = $false
$script:ConsecutiveActive = 0
$script:LastConnect = [DateTime]::MinValue
$script:LastLocalAudio = [DateTime]::MinValue
$script:IdleDisconnectDone = $false

function Get-DefaultConfig {
    [pscustomobject]@{
        DeviceNamePattern = "AirPods"
        AudioEndpointNamePattern = "AirPods"
        PeakThreshold = 0.015
        ActiveSamples = 3
        PollMs = 500
        CooldownSeconds = 10
        ForceReconnect = $false
        DisconnectWhenIdle = $false
        IdleDisconnectSeconds = 180
        SetCommunicationsDefault = $false
    }
}

function Read-AppConfig {
    $config = Get-DefaultConfig
    if (Test-Path $configPath) {
        try {
            $loaded = Get-Content $configPath -Raw | ConvertFrom-Json
            foreach ($property in $config.PSObject.Properties.Name) {
                if ($loaded.PSObject.Properties.Name -contains $property) {
                    $config.$property = $loaded.$property
                }
            }
        } catch {
            # Keep defaults if the config file was edited into an invalid shape.
        }
    }
    return $config
}

function Write-AppConfig {
    $config = [pscustomobject]@{
        DeviceNamePattern = $devicePatternBox.Text.Trim()
        AudioEndpointNamePattern = $endpointPatternBox.Text.Trim()
        PeakThreshold = [double]($thresholdBox.Value)
        ActiveSamples = [int]($activeSamplesBox.Value)
        PollMs = [int]($pollBox.Value)
        CooldownSeconds = [int]($cooldownBox.Value)
        ForceReconnect = [bool]$forceReconnectBox.Checked
        DisconnectWhenIdle = [bool]$disconnectIdleBox.Checked
        IdleDisconnectSeconds = [int]($idleSecondsBox.Value)
        SetCommunicationsDefault = [bool]$communicationsBox.Checked
    }

    $config | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

function Add-LogLine {
    param([string]$Message)

    $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $Message
    if ($logBox.InvokeRequired) {
        $logBox.BeginInvoke([Action[string]]{
            param($text)
            $logBox.AppendText($text + [Environment]::NewLine)
        }, $line) | Out-Null
    } else {
        $logBox.AppendText($line + [Environment]::NewLine)
    }
}

function Format-OperationResults {
    param([object[]]$Results)

    $ok = 0
    $failed = 0
    foreach ($result in $Results) {
        if ($result.Success) {
            $ok += 1
        } else {
            $failed += 1
        }
    }

    return "服务切换完成：成功 $ok 项，失败 $failed 项"
}

function Sync-ToggleText {
    if ($script:Monitoring) {
        $toggleButton.Text = "关闭自动切换"
        $toggleButton.BackColor = [System.Drawing.Color]::FromArgb(190, 49, 68)
        $statusValueLabel.Text = "运行中"
        $statusValueLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 120, 72)
        $toggleTrayItem.Text = "关闭自动切换"
    } else {
        $toggleButton.Text = "开启自动切换"
        $toggleButton.BackColor = [System.Drawing.Color]::FromArgb(32, 105, 214)
        $statusValueLabel.Text = "已关闭"
        $statusValueLabel.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
        $toggleTrayItem.Text = "开启自动切换"
    }
}

function Refresh-Devices {
    $selected = [string]$deviceCombo.SelectedItem
    $deviceCombo.BeginUpdate()
    try {
        $deviceCombo.Items.Clear()
        [void]$deviceCombo.Items.Add("所有 AirPods")

        $devices = [AirPodsSwitch.BluetoothTools]::ListDevices() |
            Where-Object { $_.Authenticated -or $_.Remembered } |
            Sort-Object Name

        foreach ($device in $devices) {
            if ($device.Name) {
                [void]$deviceCombo.Items.Add($device.Name)
            }
        }

        $index = 0
        if ($selected) {
            $found = $deviceCombo.Items.IndexOf($selected)
            if ($found -ge 0) {
                $index = $found
            }
        }
        $deviceCombo.SelectedIndex = $index
        Add-LogLine ("已刷新设备，共 {0} 个" -f ($deviceCombo.Items.Count - 1))
    } catch {
        Add-LogLine ("刷新设备失败：{0}" -f $_.Exception.Message)
    } finally {
        $deviceCombo.EndUpdate()
    }
}

function Connect-SelectedHeadphones {
    $pattern = $devicePatternBox.Text.Trim()
    $endpointPattern = $endpointPatternBox.Text.Trim()
    if (-not $pattern) {
        Add-LogLine "请先填写蓝牙设备匹配名称"
        return
    }

    Write-AppConfig
    $script:Busy = $true
    $toggleButton.Enabled = $false
    $connectNowButton.Enabled = $false
    $statusValueLabel.Text = "连接中"

    try {
        if ($forceReconnectBox.Checked) {
            Add-LogLine "正在刷新蓝牙音频服务..."
            $off = [AirPodsSwitch.BluetoothTools]::SetAudioStateByName(
                $pattern,
                $false,
                [bool]$communicationsBox.Checked)
            Add-LogLine (Format-OperationResults $off)
            Start-Sleep -Milliseconds 500
        }

        Add-LogLine ("正在连接：{0}" -f $pattern)
        $on = [AirPodsSwitch.BluetoothTools]::SetAudioStateByName(
            $pattern,
            $true,
            [bool]$communicationsBox.Checked)
        Add-LogLine (Format-OperationResults $on)

        Start-Sleep -Milliseconds 1800
        if ($endpointPattern) {
            $switched = [AirPodsSwitch.AudioTools]::SetDefaultRenderEndpointByName(
                $endpointPattern,
                [bool]$communicationsBox.Checked)
            if ($switched) {
                Add-LogLine ("已切换默认输出：{0}" -f $endpointPattern)
            } else {
                Add-LogLine ("还没找到可用输出端点：{0}" -f $endpointPattern)
            }
        }
    } catch {
        Add-LogLine ("连接失败：{0}" -f $_.Exception.Message)
    } finally {
        $script:LastConnect = Get-Date
        $script:ConsecutiveActive = 0
        $script:Busy = $false
        $toggleButton.Enabled = $true
        $connectNowButton.Enabled = $true
        Sync-ToggleText
    }
}

function Disconnect-SelectedHeadphones {
    $pattern = $devicePatternBox.Text.Trim()
    if (-not $pattern) {
        return
    }

    try {
        Add-LogLine ("空闲超时，正在断开：{0}" -f $pattern)
        $off = [AirPodsSwitch.BluetoothTools]::SetAudioStateByName(
            $pattern,
            $false,
            [bool]$communicationsBox.Checked)
        Add-LogLine (Format-OperationResults $off)
    } catch {
        Add-LogLine ("断开失败：{0}" -f $_.Exception.Message)
    }
}

function Start-Monitoring {
    Write-AppConfig
    $timer.Interval = [Math]::Max(250, [int]$pollBox.Value)
    $script:Monitoring = $true
    $script:ConsecutiveActive = 0
    $script:LastConnect = [DateTime]::MinValue
    $script:IdleDisconnectDone = $false
    Sync-ToggleText
    $timer.Start()
    Add-LogLine "自动切换已开启"
}

function Stop-Monitoring {
    $timer.Stop()
    $script:Monitoring = $false
    $script:ConsecutiveActive = 0
    Sync-ToggleText
    Add-LogLine "自动切换已关闭"
}

function Toggle-Monitoring {
    if ($script:Monitoring) {
        Stop-Monitoring
    } else {
        Start-Monitoring
    }
}

function Show-MainWindow {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

$config = Read-AppConfig

$form = New-Object System.Windows.Forms.Form
$form.Text = "AirPods Auto Switch"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ClientSize = New-Object System.Drawing.Size(520, 560)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "AirPods 自动切换"
$titleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 15, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(18, 16)
$titleLabel.Size = New-Object System.Drawing.Size(260, 32)
$form.Controls.Add($titleLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "状态："
$statusLabel.Location = New-Object System.Drawing.Point(358, 22)
$statusLabel.Size = New-Object System.Drawing.Size(48, 24)
$form.Controls.Add($statusLabel)

$statusValueLabel = New-Object System.Windows.Forms.Label
$statusValueLabel.Text = "已关闭"
$statusValueLabel.Location = New-Object System.Drawing.Point(405, 22)
$statusValueLabel.Size = New-Object System.Drawing.Size(90, 24)
$form.Controls.Add($statusValueLabel)

$deviceLabel = New-Object System.Windows.Forms.Label
$deviceLabel.Text = "选择设备"
$deviceLabel.Location = New-Object System.Drawing.Point(20, 64)
$deviceLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($deviceLabel)

$deviceCombo = New-Object System.Windows.Forms.ComboBox
$deviceCombo.DropDownStyle = "DropDownList"
$deviceCombo.Location = New-Object System.Drawing.Point(20, 86)
$deviceCombo.Size = New-Object System.Drawing.Size(370, 28)
$form.Controls.Add($deviceCombo)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "刷新"
$refreshButton.Location = New-Object System.Drawing.Point(405, 85)
$refreshButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($refreshButton)

$devicePatternLabel = New-Object System.Windows.Forms.Label
$devicePatternLabel.Text = "蓝牙设备匹配"
$devicePatternLabel.Location = New-Object System.Drawing.Point(20, 126)
$devicePatternLabel.Size = New-Object System.Drawing.Size(110, 20)
$form.Controls.Add($devicePatternLabel)

$devicePatternBox = New-Object System.Windows.Forms.TextBox
$devicePatternBox.Location = New-Object System.Drawing.Point(20, 148)
$devicePatternBox.Size = New-Object System.Drawing.Size(220, 26)
$devicePatternBox.Text = $config.DeviceNamePattern
$form.Controls.Add($devicePatternBox)

$endpointPatternLabel = New-Object System.Windows.Forms.Label
$endpointPatternLabel.Text = "音频输出匹配"
$endpointPatternLabel.Location = New-Object System.Drawing.Point(268, 126)
$endpointPatternLabel.Size = New-Object System.Drawing.Size(110, 20)
$form.Controls.Add($endpointPatternLabel)

$endpointPatternBox = New-Object System.Windows.Forms.TextBox
$endpointPatternBox.Location = New-Object System.Drawing.Point(268, 148)
$endpointPatternBox.Size = New-Object System.Drawing.Size(227, 26)
$endpointPatternBox.Text = $config.AudioEndpointNamePattern
$form.Controls.Add($endpointPatternBox)

$toggleButton = New-Object System.Windows.Forms.Button
$toggleButton.Text = "开启自动切换"
$toggleButton.ForeColor = [System.Drawing.Color]::White
$toggleButton.FlatStyle = "Flat"
$toggleButton.Location = New-Object System.Drawing.Point(20, 196)
$toggleButton.Size = New-Object System.Drawing.Size(220, 44)
$form.Controls.Add($toggleButton)

$connectNowButton = New-Object System.Windows.Forms.Button
$connectNowButton.Text = "立即连接"
$connectNowButton.Location = New-Object System.Drawing.Point(268, 196)
$connectNowButton.Size = New-Object System.Drawing.Size(110, 44)
$form.Controls.Add($connectNowButton)

$hideButton = New-Object System.Windows.Forms.Button
$hideButton.Text = "最小化到托盘"
$hideButton.Location = New-Object System.Drawing.Point(385, 196)
$hideButton.Size = New-Object System.Drawing.Size(110, 44)
$form.Controls.Add($hideButton)

$optionsGroup = New-Object System.Windows.Forms.GroupBox
$optionsGroup.Text = "选项"
$optionsGroup.Location = New-Object System.Drawing.Point(20, 258)
$optionsGroup.Size = New-Object System.Drawing.Size(475, 132)
$form.Controls.Add($optionsGroup)

$forceReconnectBox = New-Object System.Windows.Forms.CheckBox
$forceReconnectBox.Text = "连接前刷新蓝牙音频服务"
$forceReconnectBox.Location = New-Object System.Drawing.Point(16, 28)
$forceReconnectBox.Size = New-Object System.Drawing.Size(210, 24)
$forceReconnectBox.Checked = [bool]$config.ForceReconnect
$optionsGroup.Controls.Add($forceReconnectBox)

$communicationsBox = New-Object System.Windows.Forms.CheckBox
$communicationsBox.Text = "同时设置通话默认设备"
$communicationsBox.Location = New-Object System.Drawing.Point(248, 28)
$communicationsBox.Size = New-Object System.Drawing.Size(190, 24)
$communicationsBox.Checked = [bool]$config.SetCommunicationsDefault
$optionsGroup.Controls.Add($communicationsBox)

$disconnectIdleBox = New-Object System.Windows.Forms.CheckBox
$disconnectIdleBox.Text = "空闲后断开"
$disconnectIdleBox.Location = New-Object System.Drawing.Point(16, 62)
$disconnectIdleBox.Size = New-Object System.Drawing.Size(110, 24)
$disconnectIdleBox.Checked = [bool]$config.DisconnectWhenIdle
$optionsGroup.Controls.Add($disconnectIdleBox)

$idleSecondsBox = New-Object System.Windows.Forms.NumericUpDown
$idleSecondsBox.Minimum = 30
$idleSecondsBox.Maximum = 3600
$idleSecondsBox.Increment = 30
$idleSecondsBox.Value = [decimal]$config.IdleDisconnectSeconds
$idleSecondsBox.Location = New-Object System.Drawing.Point(130, 62)
$idleSecondsBox.Size = New-Object System.Drawing.Size(82, 26)
$optionsGroup.Controls.Add($idleSecondsBox)

$idleUnitLabel = New-Object System.Windows.Forms.Label
$idleUnitLabel.Text = "秒"
$idleUnitLabel.Location = New-Object System.Drawing.Point(218, 65)
$idleUnitLabel.Size = New-Object System.Drawing.Size(40, 20)
$optionsGroup.Controls.Add($idleUnitLabel)

$thresholdLabel = New-Object System.Windows.Forms.Label
$thresholdLabel.Text = "触发阈值"
$thresholdLabel.Location = New-Object System.Drawing.Point(16, 96)
$thresholdLabel.Size = New-Object System.Drawing.Size(70, 20)
$optionsGroup.Controls.Add($thresholdLabel)

$thresholdBox = New-Object System.Windows.Forms.NumericUpDown
$thresholdBox.Minimum = 0.001
$thresholdBox.Maximum = 0.2
$thresholdBox.DecimalPlaces = 3
$thresholdBox.Increment = 0.005
$thresholdBox.Value = [decimal]$config.PeakThreshold
$thresholdBox.Location = New-Object System.Drawing.Point(88, 94)
$thresholdBox.Size = New-Object System.Drawing.Size(76, 26)
$optionsGroup.Controls.Add($thresholdBox)

$activeSamplesLabel = New-Object System.Windows.Forms.Label
$activeSamplesLabel.Text = "连续采样"
$activeSamplesLabel.Location = New-Object System.Drawing.Point(188, 96)
$activeSamplesLabel.Size = New-Object System.Drawing.Size(70, 20)
$optionsGroup.Controls.Add($activeSamplesLabel)

$activeSamplesBox = New-Object System.Windows.Forms.NumericUpDown
$activeSamplesBox.Minimum = 1
$activeSamplesBox.Maximum = 20
$activeSamplesBox.Value = [decimal]$config.ActiveSamples
$activeSamplesBox.Location = New-Object System.Drawing.Point(260, 94)
$activeSamplesBox.Size = New-Object System.Drawing.Size(58, 26)
$optionsGroup.Controls.Add($activeSamplesBox)

$pollLabel = New-Object System.Windows.Forms.Label
$pollLabel.Text = "间隔"
$pollLabel.Location = New-Object System.Drawing.Point(334, 96)
$pollLabel.Size = New-Object System.Drawing.Size(36, 20)
$optionsGroup.Controls.Add($pollLabel)

$pollBox = New-Object System.Windows.Forms.NumericUpDown
$pollBox.Minimum = 250
$pollBox.Maximum = 5000
$pollBox.Increment = 250
$pollBox.Value = [decimal]$config.PollMs
$pollBox.Location = New-Object System.Drawing.Point(372, 94)
$pollBox.Size = New-Object System.Drawing.Size(78, 26)
$optionsGroup.Controls.Add($pollBox)

$cooldownLabel = New-Object System.Windows.Forms.Label
$cooldownLabel.Text = "冷却秒数"
$cooldownLabel.Location = New-Object System.Drawing.Point(248, 65)
$cooldownLabel.Size = New-Object System.Drawing.Size(70, 20)
$optionsGroup.Controls.Add($cooldownLabel)

$cooldownBox = New-Object System.Windows.Forms.NumericUpDown
$cooldownBox.Minimum = 3
$cooldownBox.Maximum = 300
$cooldownBox.Value = [decimal]$config.CooldownSeconds
$cooldownBox.Location = New-Object System.Drawing.Point(324, 62)
$cooldownBox.Size = New-Object System.Drawing.Size(64, 26)
$optionsGroup.Controls.Add($cooldownBox)

$peakLabel = New-Object System.Windows.Forms.Label
$peakLabel.Text = "当前音量峰值"
$peakLabel.Location = New-Object System.Drawing.Point(20, 404)
$peakLabel.Size = New-Object System.Drawing.Size(100, 22)
$form.Controls.Add($peakLabel)

$peakBar = New-Object System.Windows.Forms.ProgressBar
$peakBar.Location = New-Object System.Drawing.Point(122, 403)
$peakBar.Size = New-Object System.Drawing.Size(373, 22)
$peakBar.Minimum = 0
$peakBar.Maximum = 100
$form.Controls.Add($peakBar)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 438)
$logBox.Size = New-Object System.Drawing.Size(475, 96)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$form.Controls.Add($logBox)

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem("显示窗口")
$toggleTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem("开启自动切换")
$exitTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem("退出")
[void]$trayMenu.Items.Add($showTrayItem)
[void]$trayMenu.Items.Add($toggleTrayItem)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add($exitTrayItem)

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$notifyIcon.Text = "AirPods Auto Switch"
$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Visible = $true

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(250, [int]$config.PollMs)

$deviceCombo.Add_SelectedIndexChanged({
    $selected = [string]$deviceCombo.SelectedItem
    if (-not $selected) {
        return
    }

    if ($selected -eq "所有 AirPods") {
        $devicePatternBox.Text = "AirPods"
        $endpointPatternBox.Text = "AirPods"
    } else {
        $cleanName = $selected -replace "\s+-\s+Find My.*$", ""
        $devicePatternBox.Text = $cleanName
        if ($cleanName -match "AirPods") {
            $endpointPatternBox.Text = "AirPods"
        } else {
            $endpointPatternBox.Text = $cleanName
        }
    }
})

$refreshButton.Add_Click({ Refresh-Devices })
$toggleButton.Add_Click({ Toggle-Monitoring })
$connectNowButton.Add_Click({ Connect-SelectedHeadphones })
$hideButton.Add_Click({ $form.Hide() })
$showTrayItem.Add_Click({ Show-MainWindow })
$toggleTrayItem.Add_Click({ Toggle-Monitoring })
$notifyIcon.Add_DoubleClick({ Show-MainWindow })
$exitTrayItem.Add_Click({
    $script:AllowExit = $true
    $timer.Stop()
    $notifyIcon.Visible = $false
    $form.Close()
})

$form.Add_FormClosing({
    if (-not $script:AllowExit -and $script:Monitoring) {
        $_.Cancel = $true
        $form.Hide()
        $notifyIcon.ShowBalloonTip(1200, "AirPods Auto Switch", "自动切换仍在后台运行", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $timer.Stop()
        $notifyIcon.Visible = $false
        Write-AppConfig
    }
})

$timer.Add_Tick({
    if ($script:Busy) {
        return
    }

    try {
        $now = Get-Date
        $peak = [AirPodsSwitch.AudioTools]::GetDefaultRenderPeak()
        $peakBar.Value = [Math]::Min(100, [int]($peak * 100))

        if (-not $script:Monitoring) {
            return
        }

        $isActive = $peak -ge [double]$thresholdBox.Value
        if ($isActive) {
            $script:ConsecutiveActive += 1
            $script:LastLocalAudio = $now
            $script:IdleDisconnectDone = $false
        } else {
            $script:ConsecutiveActive = 0
        }

        $cooldownPassed = (($now - $script:LastConnect).TotalSeconds -ge [int]$cooldownBox.Value)
        if ($script:ConsecutiveActive -ge [int]$activeSamplesBox.Value -and $cooldownPassed) {
            Add-LogLine ("检测到本机播放，峰值 {0:N3}" -f $peak)
            $timer.Stop()
            Connect-SelectedHeadphones
            if ($script:Monitoring) {
                $timer.Start()
            }
            return
        }

        if ($disconnectIdleBox.Checked -and -not $script:IdleDisconnectDone -and $script:LastLocalAudio -ne [DateTime]::MinValue) {
            $idleSeconds = (($now - $script:LastLocalAudio).TotalSeconds)
            if ($idleSeconds -ge [int]$idleSecondsBox.Value) {
                $timer.Stop()
                Disconnect-SelectedHeadphones
                $script:IdleDisconnectDone = $true
                if ($script:Monitoring) {
                    $timer.Start()
                }
            }
        }
    } catch {
        Add-LogLine ("监听出错：{0}" -f $_.Exception.Message)
    }
})

Refresh-Devices
Sync-ToggleText
Add-LogLine "应用已启动"

if ($SmokeTest) {
    Write-Output ("OK: app loaded; device choices={0}" -f $deviceCombo.Items.Count)
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $timer.Dispose()
    $form.Dispose()
    exit 0
}

[System.Windows.Forms.Application]::Run($form)

$notifyIcon.Dispose()
$timer.Dispose()

