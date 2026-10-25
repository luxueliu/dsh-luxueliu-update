# Windows 上写更新脚本的三个坑

> 三个都是实打实测出来的，不是理论推导。每个都足以让脚本"看着在跑、其实没干活"。

## 坑 1：`Start-Process` 会在某些机器上直接崩

**现象**：脚本执行到启动/调用那一步，抛

```
Start-Process : Item has been added. Key in dictionary: 'HTTPS_PROXY'
Key being added: 'https_proxy'
```

命令压根没发出去，进程自然没起来。

**原因**：PowerShell 5.1 的 `Start-Process` 内部用一个**不区分大小写**的字典处理环境变量。
只要环境里同时存在 `HTTPS_PROXY` 和 `https_proxy`（装了代理工具的机器上很常见），就撞key、抛异常。

**还要注意**：这个坑**只在某些环境里出现**。同一份脚本在干净的机器上跑得好好的，
到有代理的机器上就炸——所以极难复现，也极难归因。

**怎么办**：全程改用 `ProcessStartInfo` + `[System.Diagnostics.Process]::Start()`，别碰 `Start-Process`。

```powershell
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.WorkingDirectory = $exeDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
[void][System.Diagnostics.Process]::Start($psi)
```

## 坑 2：子进程继承了你的控制台，控制台一关它就没了

**现象**：脚本拉起了 DSH，进程确实在；过一会儿——尤其是窗口关掉之后——进程没了。

**原因**：子进程默认继承父进程的控制台。控制台被关闭时，Windows 会给**所有附加到该控制台的进程**
发送 `CTRL_CLOSE_EVENT`，默认处理就是退出。

**`UseShellExecute = $true` 挡不住这个。**

**怎么办**：显式 `CreateNoWindow = $true`（对应 `CREATE_NO_WINDOW`），子进程既不新建控制台也不继承控制台。
GUI 窗口照常显示——这不等于 `-WindowStyle Hidden`，窗口还是看得见的。

类似地，如果你用的是 `cmd /c start "" ...` 这种绕法，不如直接用 `ProcessStartInfo`，省一层不确定性。

## 坑 3：在应用还开着的时候改 app.asar，必吃 EPERM

**现象**：打补丁脚本跑到最后一步 `rename(tmp, app.asar)` 崩：

```
errno: -4048, code: 'EPERM', syscall: 'rename'
```

留下一坨几百 MB 的临时文件，而且**脚本崩了不留任何报告**。

**原因**：Windows 上，被打开的文件不能被替换或改名。Electron 运行时占着 `app.asar`，
你在外面想重命名它，操作系统直接拒绝。

**怎么办**：补丁必须排在**应用完全退出之后**。这也是本项目把钩子设计在
"官方安装包已跑完、DSH 尚未重新启动"这个位置的根本原因——那个窗口期里没有任何文件锁。

补充两点：

- 确认进程真的退出了再动手。优雅关闭优先（发关窗消息），超时才强杀，杀完还要轮询确认进程数为 0。
- 即使如此，重命名仍建议加重试。旧脚本发生过"崩了但没报错"，导致后面的回退没人发现。

## 一句话总结

在 Windows 上写这类脚本：

> 别用 `Start-Process`，别让子进程继承控制台，别在应用开着的时候动它的文件。

三条都违反了，脚本就会呈现"全程绿、其实什么都没干成"这种最糟糕的失败形态。
