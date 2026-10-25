# ============================================================
#  在桌面生成「更新 DSH」按钮
#  用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\install-button.ps1
#  可选： -ShortcutName "更新 DSH"   -DesktopPath "某个目录"
# ============================================================
[CmdletBinding()]
param(
    [string]$ShortcutName = '更新 DSH',
    [string]$DesktopPath
)
$ErrorActionPreference = 'Stop'

$repo = $PSScriptRoot
$wrapper = Join-Path $repo 'update-dsh.cmd'
if (-not (Test-Path -LiteralPath $wrapper)) { throw ('找不到入口文件：' + $wrapper) }

if (-not $DesktopPath) {
    $DesktopPath = [Environment]::GetFolderPath('Desktop')
}
if (-not (Test-Path -LiteralPath $DesktopPath)) { throw ('桌面目录不存在：' + $DesktopPath) }

$lnk = Join-Path $DesktopPath ($ShortcutName + '.lnk')
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = $wrapper
$sc.WorkingDirectory = $repo
$sc.Description = 'dsh-updater：官方安装包 + 数据保全 + 更新后钩子'
$sc.IconLocation = 'shell32.dll,46'
$sc.Save()

Write-Host ('已生成按钮：' + $lnk) -ForegroundColor Green
Write-Host '双击即可运行；想先只看不更，右击 → 属性 → 目标里加 -CheckOnly' -ForegroundColor DarkGray
exit 0
