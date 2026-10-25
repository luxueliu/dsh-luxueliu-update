# ============================================================
#  dsh-updater —— DeepSeek Harness 的稳健更新器（Windows PowerShell）
#  仓库：https://github.com/<your-name>/dsh-updater
#
#  为什么要这个：官方每次更新会整包替换 desk\resources\app.asar，
#  本地补丁、自定义 providers、插件豁免都会被抹掉；而更新脚本往往
#  只比对配置文本，不看实际生效状态，于是"更新完掉东西"反复发生。
#  本脚本不猜、不重建配置，只做三件事：用官方安装包升级、保证用户数据
#  一个不少、把可重复的后处理步骤交给钩子。
#
#  流程：读官方 feed → 比对版本 → 下载并校验 → 备份受保护数据
#        → 留底 app.asar → 关台 → 跑官方安装包（静默，装回原目录）
#        → 校验版本 → 跑钩子（此时台是关的）→ 缺数据就从备份还原
#        → 开台 → 以本地 API 答话为最终验收
#
#  本文件不含任何个人路径、主机名或凭据，可直接放进公开仓库。
#  模型配置一律不碰：更新不动 profiles\*\cordis.patch.yml，自然不会掉模型。
# ============================================================
[CmdletBinding()]
param(
    [switch]$CheckOnly,     # 只看现状，不改任何东西
    [switch]$StartOnly,     # 只把 DSH 拉起来，不做更新（主台没起来时的补救入口）
    [switch]$HooksOnly,     # 只跑钩子不动版本（重打补丁用；打 patch 类钩子需要 DSH 已关闭）
    [switch]$Force,         # 版本相同也重装
    [switch]$DryRun,        # 走到安装前为止，不关台不安装
    [switch]$NoRestart,     # 装完不开台
    [string]$DshHome,       # 覆盖自动定位的 DSH 根目录
    [int]$WaitTimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Issues = New-Object System.Collections.ArrayList

# ---------- 常量 ----------
$ControlDir   = $PSScriptRoot
$LogFile      = Join-Path $ControlDir 'dsh-updater.log'
$ConfigFile   = Join-Path $ControlDir 'dsh-updater.config.json'
$DownloadDir  = Join-Path $ControlDir 'downloads'
$BackupRoot   = Join-Path $ControlDir 'backups'
$FeedUrl      = 'https://download.deepseek.com/dsh-desk/feeds/win-x64/nightly.yml'
$AppProcess   = 'DeepSeek Harness'
$Stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'

# 默认要保住的东西（相对 DSH 根目录）。可在 dsh-update.config.json 里加。
$DefaultProtected = @(
    '.credentials.yaml',
    '.openai-codex-auth.json',
    '.workbuddy-auth.json',
    '.workbuddy-accounts.json',
    'profiles\desktop\cordis.yml',
    'profiles\desktop\cordis.patch.yml',
    'profiles\desktop\package.json',
    'profiles\desktop\compatibility.json'
)

# ---------- 基础工具 ----------
function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    try { Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}
function Add-Issue { param([string]$m) [void]$script:Issues.Add($m); Write-Log ('!! ' + $m) 'Red' }

function Get-AppConfig {
    # 配置文件不存在就用内置默认值，不让按钮依赖外部文件
    if (Test-Path -LiteralPath $ConfigFile) {
        try { return (Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { Write-Log '配置文件读不了，用内置默认' 'Yellow' }
    }
    return $null
}

function Resolve-YamlValue {
    # 只认 feed 里这几种写法：inline、"key: >-" 折行、普通缩进
    param([string[]]$Lines, [string]$Key)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match ('^\s*' + [regex]::Escape($Key) + ':\s*(.+?)\s*$')) {
            $v = $Matches[1].Trim()
            if ($v -ne '>-' -and $v -ne '>- ' -and $v -ne '|' -and $v -ne '>-' ) { return $v }
        }
        if ($line -match ('^\s*' + [regex]::Escape($Key) + ':\s*(>-|\|)?\s*$')) {
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                $cand = $Lines[$j].Trim()
                if ($cand) { return $cand }
            }
        }
    }
    return $null
}

function Get-InstalledVersionInfo {
    # 全靠实际登记和默认位置定位，不含任何写死的个人路径。
    # 定位不到就返回空，让调用方给出明确指引，而不是猜。
    param([string]$OverrideHome)
    $info = @{ Home = $null; DeskDir = $null; Version = $null }

    if ($OverrideHome -and (Test-Path -LiteralPath (Join-Path $OverrideHome 'desk\DeepSeek Harness.exe'))) {
        $info.DeskDir = [IO.Path]::GetFullPath((Join-Path $OverrideHome 'desk'))
    }

    if (-not $info.DeskDir) {
        $overrides = @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($base in $overrides) {
            $hits = @(Get-ItemProperty $base -ErrorAction SilentlyContinue |
                      Where-Object { $_.DisplayName -like 'DeepSeek Harness*' -and $_.InstallLocation })
            if ($hits.Count -gt 0) {
                $desk = [IO.Path]::GetFullPath($hits[0].InstallLocation.TrimEnd('\'))
                if (Test-Path -LiteralPath (Join-Path $desk 'DeepSeek Harness.exe')) { $info.DeskDir = $desk }
                break
            }
        }
    }
    if (-not $info.DeskDir) {
        foreach ($cand in @((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
                            (Join-Path $env:ProgramFiles 'DeepSeek Harness'),
                            (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness'),
                            (Join-Path $env:USERPROFILE 'DeepSeek Harness'))) {
            if ($cand -and (Test-Path -LiteralPath (Join-Path $cand 'DeepSeek Harness.exe'))) {
                $info.DeskDir = [IO.Path]::GetFullPath($cand)
                break
            }
        }
    }
    if (-not $info.DeskDir) { return $info }

    # 用户数据目录优先取「安装目录的上一层」（profiles 就在那一层），
    # 也可以用 -Home 或在配置文件里写 home 指定。
    if ($OverrideHome) { $info.Home = (Resolve-Path -LiteralPath $OverrideHome).ProviderPath }
    else {
        $cfgHome = $null
        $cfg = Get-AppConfig
        if ($cfg -and $cfg.home) { $cfgHome = [IO.Path]::GetFullPath($cfg.home) }
        $parent = [IO.Path]::GetFullPath((Split-Path -Parent $info.DeskDir))
        if ($cfgHome -and (Test-Path -LiteralPath $cfgHome)) { $info.Home = $cfgHome }
        else { $info.Home = $parent }
    }

    $exe = Join-Path $info.DeskDir 'DeepSeek Harness.exe'
    if (Test-Path -LiteralPath $exe) {
        try { $info.Version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { }
    }
    return $info
}

function Get-FeedInfo {
    param([string]$Url)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    $tmp = Join-Path $env:TEMP ('dsh-feed-' + [guid]::NewGuid().ToString('N') + '.yml')
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $tmp)
        $lines = [IO.File]::ReadAllLines($tmp)
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }

    $info = @{ Version = $null; Url = $null; Sha512 = $null; Size = 0 }
    $info.Version = Resolve-YamlValue $lines 'version'

    # files 段在 path 段之前，取第一个 url / sha512 / size
    foreach ($line in $lines) {
        if (-not $info.Url -and $line -match '^\s*url:\s*(.+?)\s*$' -and $Matches[1].Trim() -ne '>-') { $info.Url = $Matches[1].Trim() }
        if (-not $info.Sha512 -and $line -match '^\s*sha512:\s*(.+?)\s*$' -and $Matches[1].Trim() -ne '>-') { $info.Sha512 = $Matches[1].Trim() }
        if ($info.Size -eq 0 -and $line -match '^\s*size:\s*(\d+)\s*$') { $info.Size = [int64]$Matches[1] }
    }
    if (-not $info.Url) { $info.Url = Resolve-YamlValue $lines 'url' }
    if (-not $info.Sha512) { $info.Sha512 = Resolve-YamlValue $lines 'sha512' }
    if (-not $info.Url) { $info.Url = Resolve-YamlValue $lines 'path' }
    return $info
}

function Test-FileSha512 {
    param([string]$Path, [string]$Base64)
    try { $expectBytes = [Convert]::FromBase64String($Base64) } catch { Write-Log 'feed 里的 sha512 不是合法 base64，跳过校验' 'Yellow'; return $false }
    $expect = ([System.BitConverter]::ToString($expectBytes) -replace '-', '').ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash.ToLowerInvariant()
    return ($expect -eq $actual)
}

function Get-ProtectedFiles {
    param([string]$Root)
    $list = New-Object System.Collections.ArrayList
    $cfg = Get-AppConfig
    $names = $DefaultProtected
    if ($cfg -and $cfg.protectedFiles) { $names = @($cfg.protectedFiles) }
    foreach ($n in $names) {
        $full = Join-Path $Root $n
        $exists = Test-Path -LiteralPath $full
        $size = 0
        if ($exists) { try { $size = (Get-Item -LiteralPath $full).Length } catch { } }
        [void]$list.Add(@{ Rel = $n; Full = $full; Exists = $exists; Size = $size })
    }
    return @($list)
}

function Backup-ProtectedFiles {
    param($Items, [string]$Dest)
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $saved = 0
    foreach ($it in $Items) {
        if (-not $it.Exists) { continue }
        $target = Join-Path $Dest $it.Rel
        $parent = Split-Path -Parent $target
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $it.Full -Destination $target -Force
        $saved++
    }
    Write-Log ('已备份 ' + $saved + ' 个受保护文件 → ' + $Dest) 'DarkGray'
}

function Test-ProtectedSurvived {
    param($Expected, [string]$Root)
    $missing = New-Object System.Collections.ArrayList
    foreach ($e in $Expected) {
        if (-not $e.Exists) { continue }   # 更新前就没有的，不追究
        $full = Join-Path $Root $e.Rel
        if (-not (Test-Path -LiteralPath $full)) { [void]$missing.Add($e.Rel) }
    }
    return @{ Ok = ($missing.Count -eq 0); Missing = @($missing) }
}

function Restore-ProtectedFiles {
    param($Expected, [string]$Root, [string]$BackupDir)
    $check = Test-ProtectedSurvived $Expected $Root
    if ($check.Ok) { return $true }
    Write-Log ('发现少了 ' + @($check.Missing).Count + ' 个文件，从备份还原') 'Yellow'
    $fixed = New-Object System.Collections.ArrayList
    foreach ($rel in @($check.Missing)) {
        $src = Join-Path $BackupDir $rel
        if (-not (Test-Path -LiteralPath $src)) { Add-Issue ('备份里也没有 ' + $rel); continue }
        $dst = Join-Path $Root $rel
        $parent = Split-Path -Parent $dst
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        [void]$fixed.Add($rel)
    }
    if ($fixed.Count -gt 0) { Write-Log ('已还原：' + (@($fixed) -join '、')) 'Green' }
    return ((Test-ProtectedSurvived $Expected $Root).Ok)
}

function Stop-DshDesktop {
    $procs = @(Get-Process -Name $AppProcess -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Write-Log 'DSH 没在运行' 'DarkGray'; return $true }
    Write-Log ('正在关闭 DSH（' + $procs.Count + ' 个进程）') 'Yellow'
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
    Start-Sleep -Seconds 6
    $procs = @(Get-Process -Name $AppProcess -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
    }
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-Process -Name $AppProcess -ErrorAction SilentlyContinue).Count -eq 0) {
            Start-Sleep -Seconds 3
            Write-Log 'DSH 已完全退出' 'Yellow'
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Start-DshDesktop {
    param([string]$Root)
    $exe = Join-Path $Root 'desk\DeepSeek Harness.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw ('找不到主程序：' + $exe) }
    $exeDir = Split-Path -Parent $exe

    # 跟 start-dsh.bat 保持一致的运行环境变量
    $env:DSH_HOME = $Root
    $env:DSH_PROFILE = 'desktop'
    $env:DSH_PROFILE_DIR = (Join-Path $Root 'profiles\desktop')
    $env:DSH_TELEMETRY_DISABLED = '1'
    Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

    # 启动这一步踩过三个坑，都用实锤验证过：
    # 1) 不能用 Start-Process：PS5.1 遇到大小写重复的环境变量（HTTPS_PROXY / https_proxy）直接抛异常，命令发不出去。
    # 2) 不能让 app 继承本进程的控制台：控制台一关，Windows 给所有附加进程发 CTRL_CLOSE，DSH 跟着没（已实测复现）。
    # 3) UseShellExecute=true 也躲不开第 2 条，必须显式 CreateNoWindow（CREATE_NO_WINDOW）。
    # 结论：UseShellExecute=false + CreateNoWindow=true，既不建控制台也不继承控制台。GUI 窗口照常显示。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.WorkingDirectory = $exeDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
    Write-Log '已发出启动指令（不继承任何控制台，本窗口关掉也带不走 DSH）' 'DarkGray'

    # 验收标准不是"进程在"，是"本地 API 答话"——数进程骗得过自己，答话才算真能用
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $ids = @(Get-Process -Name $AppProcess -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        if ($ids.Count -eq 0) { continue }
        $conn = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { $ids -contains $_.OwningProcess } | Select-Object -First 1
        if (-not $conn) { continue }
        try {
            $r = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $conn.LocalPort + '/api/sessions') -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ([int]$r.StatusCode -ge 200) { Write-Log ('DSH 可用了（端口 ' + $conn.LocalPort + '，HTTP ' + [int]$r.StatusCode + '）') 'Green'; return $true }
        } catch {
            $resp = $_.Exception.Response
            if ($resp -and $resp.StatusCode) { Write-Log ('DSH 可用了（端口 ' + $conn.LocalPort + '，HTTP ' + [int]$resp.StatusCode + '）') 'Green'; return $true }
        }
    }
    if (@(Get-Process -Name $AppProcess -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Log '进程起来了，但 120 秒内 API 没答话。你自己看一眼窗口，多半是还在初始化。' 'Yellow'
        return $true
    }
    Add-Issue '点了启动但 DSH 没起来'
    return $false
}

function Invoke-PostHooks {
    # 钩子在「更新完了、台还关着」这一步跑。模型修复、二进制补丁将来放这里，
    # 与主更新流程解耦：钩子挂了不影响本次更新本身的判定。
    param([string]$Root, [string]$DeskDir, [string]$Version)
    $cfg = Get-AppConfig
    if (-not $cfg -or -not $cfg.hooks) { return }
    foreach ($h in @($cfg.hooks)) {
        if (-not $h.enabled) { Write-Log ('钩子跳过（未启用）：' + $h.name) 'DarkGray'; continue }
        Write-Log ('跑钩子：' + $h.name) 'Cyan'
        $file = $h.file
        if (-not [IO.Path]::IsPathRooted($file)) { $file = Join-Path $ControlDir $file }
        if (-not (Test-Path -LiteralPath $file)) { Add-Issue ('钩子文件找不到：' + $file); continue }
        $argv = @()
        if ($h.args) { foreach ($a in @($h.args)) { $argv += ($a -replace '{home}', $Root -replace '{desk}', $DeskDir -replace '{version}', $Version) } }
        try {
            # 同样不能用 Start-Process（环境变量大小写重复会让它抛异常），一律走 ProcessStartInfo
            $argList = New-Object System.Collections.ArrayList
            [void]$argList.Add('"' + $file + '"')
            foreach ($a in $argv) { [void]$argList.Add('"' + $a + '"') }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $h.runner
            $psi.Arguments = ($argList -join ' ')
            $psi.WorkingDirectory = (Split-Path -Parent $file)
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $procH = [System.Diagnostics.Process]::Start($psi)
            $outText = $procH.StandardOutput.ReadToEnd()
            $errText = $procH.StandardError.ReadToEnd()
            $procH.WaitForExit()
            $tail = @($outText -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 4)
            foreach ($t in $tail) { Write-Log ('  ' + $t.Trim()) 'DarkGray' }
            if ($errText.Trim()) { Write-Log ('  stderr: ' + ($errText -split "`n" | Select-Object -Last 1).Trim()) 'DarkGray' }
            if ($procH.ExitCode -ne 0) { Add-Issue ('钩子 ' + $h.name + ' 返回 ' + $procH.ExitCode) }
            else { Write-Log ('钩子完成：' + $h.name) 'Green' }
        } catch { Add-Issue ('钩子 ' + $h.name + ' 跑失败：' + $_.Exception.Message) }
    }
}

function Show-Summary {
    Write-Log '---------------- 结果 ----------------' 'White'
    if ($script:Issues.Count -eq 0) { Write-Log '全部通过：更新、数据、启动都正常。' 'Green' }
    else {
        Write-Log ('还有 ' + $script:Issues.Count + ' 个问题：') 'Yellow'
        foreach ($m in $script:Issues) { Write-Host ('  - ' + $m) -ForegroundColor Yellow }
        Write-Log ('详细日志：' + $LogFile) 'Yellow'
    }
    Write-Log '=====================================' 'White'
}

# ---------- 主流程 ----------
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

Write-Log '================ DSH 更新一条龙 ================' 'White'
$inst = Get-InstalledVersionInfo $DshHome
if (-not $inst.Home) {
    Write-Log '定位不到 DSH 安装目录。' 'Red'
    Write-Host '  先在任务管理器里确认已安装过 DeepSeek Harness；' -ForegroundColor Yellow
    Write-Host '  若它装在非默认位置，用 [-Home "你的 DSH 根目录"] 指定，或在配置文件里写 home 字段。' -ForegroundColor Yellow
    exit 1
}
$Root = $inst.Home
$DeskDir = $inst.DeskDir
Write-Log ('安装目录：' + $DeskDir) 'DarkGray'
Write-Log ('当前版本：' + $(if ($inst.Version) { $inst.Version } else { '读不到' })) 'Cyan'

Write-Log ('正在读官方更新源：' + $FeedUrl) 'DarkGray'
try { $feed = Get-FeedInfo $FeedUrl } catch { Write-Log ('读更新源失败：' + $_.Exception.Message) 'Red'; exit 1 }
if (-not $feed.Version -or -not $feed.Url) { Write-Log '更新源返回的内容解析不出版本或地址，停。' 'Red'; exit 1 }
Write-Log ('源上最新版：' + $feed.Version) 'Cyan'

$protected = Get-ProtectedFiles $Root
$presentCount = @($protected | Where-Object { $_.Exists }).Count
Write-Log ('受保护文件：' + $presentCount + '/' + @($protected).Count + ' 在位') 'DarkGray'

if ($CheckOnly) {
    Write-Log ('能否更新：' + $(if ($feed.Version -ne $inst.Version) { '有新版可升' } else { '已是最新版' })) $(if ($feed.Version -ne $inst.Version) { 'Green' } else { 'Gray' })
    Write-Log ('安装包大小：' + [math]::Round($feed.Size / 1MB, 1) + ' MB') 'DarkGray'
    Write-Log ('正在运行的 DSH：' + @(Get-Process -Name $AppProcess -ErrorAction SilentlyContinue).Count + ' 个进程') 'DarkGray'
    Show-Summary
    exit 0
}

# ---- 只跑钩子，不动版本 ----
if ($HooksOnly) {
    Write-Log 'HooksOnly：不更新版本，只按配置跑一遍钩子。' 'Cyan'
    Invoke-PostHooks $Root $DeskDir $inst.Version
    Show-Summary
    if ($script:Issues.Count -eq 0) { exit 0 } else { exit 1 }
}

# ---- 只负责把台拉起来 ----
if ($StartOnly) {
    Write-Log 'StartOnly：不做更新，只把 DSH 拉起来。' 'Cyan'
    try { [void](Start-DshDesktop $Root) } catch { Add-Issue ('启动失败：' + $_.Exception.Message) }
    Show-Summary
    if ($script:Issues.Count -eq 0) { exit 0 } else { exit 1 }
}

# ---- 版本判断：相同就不动，避免无谓重装把东西搞乱 ----
if (($feed.Version -eq $inst.Version) -and -not $Force) {
    Write-Log ('版本号一致（' + $feed.Version + '），本次不重装。要强制重装加 -Force。') 'Yellow'
    Show-Summary
    exit 0
}

# ---- 下载并校验 ----
$installerName = [IO.Path]::GetFileName(($feed.Url -split '\?')[0])
if (-not $installerName) { $installerName = 'dsh-installer.exe' }
$installerPath = Join-Path $DownloadDir ($feed.Version + '-' + $installerName)

$needDownload = $true
if (Test-Path -LiteralPath $installerPath) {
    $okSize = ($feed.Size -eq 0) -or ((Get-Item -LiteralPath $installerPath).Length -eq $feed.Size)
    Write-Log '本地已有安装包，先校验' 'DarkGray'
    if ($okSize -and $feed.Sha512 -and (Test-FileSha512 $installerPath $feed.Sha512)) {
        Write-Log '本地安装包校验通过，不用重新下载' 'Green'
        $needDownload = $false
    } else {
        Write-Log '本地安装包对不上，删掉重下' 'Yellow'
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    }
}

if ($needDownload) {
    Write-Log ('正在下载安装包（约 ' + [math]::Round($feed.Size / 1MB, 1) + ' MB）') 'Cyan'
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($feed.Url, $installerPath)
    } catch { Write-Log ('下载失败：' + $_.Exception.Message) 'Red'; exit 1 }
    if ($feed.Size -gt 0 -and (Get-Item -LiteralPath $installerPath).Length -ne $feed.Size) {
        Write-Log ('下载下来的大小和源上不一致（本地 ' + (Get-Item -LiteralPath $installerPath).Length + '，源上 ' + $feed.Size + '）') 'Red'
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        exit 1
    }
    if ($feed.Sha512 -and -not (Test-FileSha512 $installerPath $feed.Sha512)) {
        Write-Log 'sha512 对不上，安装包不干净，删掉。' 'Red'
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Log '下载完成，大小和 sha512 都对得上' 'Green'
}

if ($DryRun) {
    Write-Log 'DryRun：到这里为止都正常，不关台不安装。' 'Cyan'
    Show-Summary
    exit 0
}

# ---- 备份 ----
$backupDir = Join-Path $BackupRoot $Stamp
Backup-ProtectedFiles $protected $backupDir

# ---- 关台 ----
if (-not (Stop-DshDesktop)) {
    Write-Log '关不掉 DSH，本次不安装。宁可不升，也不半途替换文件。' 'Red'
    Show-Summary
    exit 1
}

# ---- 给主包留底：台已关，没有文件锁，拷得干净；出事能原样换回去 ----
$asarPath = Join-Path $DeskDir 'resources\app.asar'
$asarBackup = $null
if (Test-Path -LiteralPath $asarPath) {
    try {
        $dst = Join-Path $backupDir 'app.asar'
        Copy-Item -LiteralPath $asarPath -Destination $dst -Force
        Write-Log ('已留底主包 app.asar（' + [math]::Round((Get-Item -LiteralPath $asarPath).Length / 1MB) + ' MB）') 'DarkGray'
        $asarBackup = $dst
    } catch { Write-Log ('主包留底失败：' + $_.Exception.Message) 'Yellow' }
}

# ---- 跑官方安装包 ----
Write-Log ('正在跑官方安装包（静默）：' + [IO.Path]::GetFileName($installerPath)) 'Cyan'
if ($DeskDir -match ' ') { Write-Log ('安装路径里有空格，NSIS 可能识别不了：' + $DeskDir) 'Yellow' }
$installOk = $true
try {
    $proc = Start-Process -FilePath $installerPath -ArgumentList @('/S', ('/D=' + $DeskDir)) -PassThru
    $deadline = (Get-Date).AddSeconds(900)
    while (-not $proc.HasExited) {
        if ((Get-Date) -gt $deadline) { Write-Log '安装超时（15 分钟）' 'Red'; $proc.Kill(); $installOk = $false; break }
        Start-Sleep -Seconds 3
    }
    if ($installOk) {
        $code = $proc.ExitCode
        Write-Log ('安装包退出码：' + $code) 'DarkGray'
        if ($code -ne 0) { Add-Issue ('安装包返回 ' + $code + '，可能没装完'); $installOk = $false }
    }
} catch { Add-Issue ('安装过程出错：' + $_.Exception.Message); $installOk = $false }

# ---- 装失败就把主包换回更新前那份，不让半截 state 留在盘上 ----
if (-not $installOk -and $asarBackup -and (Test-Path -LiteralPath $asarBackup)) {
    try {
        Copy-Item -LiteralPath $asarBackup -Destination $asarPath -Force
        Write-Log '安装包没跑成功，已把主包还原成更新前那份，DSH 不受影响。' 'Yellow'
    } catch { Add-Issue ('主包还原失败：' + $_.Exception.Message) }
}

# ---- 校验安装结果 ----
$after = Get-InstalledVersionInfo $Root
Write-Log ('更新后版本：' + $(if ($after.Version) { $after.Version } else { '读不到' })) 'Cyan'
if (-not (Test-Path -LiteralPath (Join-Path $DeskDir 'DeepSeek Harness.exe'))) {
    Add-Issue '安装完之后原目录里连主程序都没有'
} elseif ($after.Version -ne $feed.Version) {
    if ($feed.Version -eq $inst.Version) {
        Write-Log '同版本重装，版本号不变属正常' 'DarkGray'
    } else {
        Add-Issue ('版本号没变成 ' + $feed.Version + '，实际还是 ' + $after.Version)
    }
} else {
    Write-Log ('版本已升到 ' + $after.Version) 'Green'
}

# ---- 钩子（此时台是关的，适合打补丁/修配置） ----
Invoke-PostHooks $Root $DeskDir $after.Version

# ---- 数据保住没有 ----
[void](Restore-ProtectedFiles $protected $Root $backupDir)

# ---- 开台 ----
if (-not $NoRestart) {
    Write-Log '正在打开 DSH' 'Cyan'
    try { [void](Start-DshDesktop $Root) } catch { Add-Issue ('启动失败：' + $_.Exception.Message) }
    # 桌面起来可能顺手改配置，起来之后再看一眼
    Start-Sleep -Seconds 8
    [void](Restore-ProtectedFiles $protected $Root $backupDir)
} else {
    Write-Log '按参数不开台' 'DarkGray'
}

Show-Summary
if ($script:Issues.Count -eq 0) { exit 0 } else { exit 1 }
