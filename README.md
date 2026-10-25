# dsh-luxueliu-update

顾名思义：一个稳健的DSH更新器。
解决DSH更新带来的以下问题：掉模型、掉订阅套餐、掉插件、掉补丁、掉DSH（报错起不来）

安装方式：
```powershell
git clone https://github.com/luxueliu/dsh-luxueliu-update.git
cd dsh-luxueliu-update
Copy-Item config.example.json dsh-luxueliu-update.config.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-button.ps1
```
---

## 开发原因

官方每次更新会**整包替换 `resources\app.asar`**，于是本地补丁、自定义 `providers`、插件版本豁免全部被抹掉。
而大多数自己写的更新脚本，验收办法是"读配置文件、数 YAML 行"——**它检查的是文本，不是生效状态**，所以掉再多东西也不报错。

`dsh-luxueliu-update` 的做法很笨也很稳：

1. **只用官方安装包升级。** 官方 NSIS 包静默装回原目录，文件注册、卸载项、快捷方式都由官方自己处理。
2. **模型配置一个字不碰。** 更新不读也不写 `profiles\*\cordis.patch.yml`。没有"重建"，就不会"重建错"。这一条比任何修复脚本都管用。
3. **数据保全用清单核对 + 备份链还原。** 更新前逐个记录受保护文件，更新后发现少了就从备份还原；DSH 起来后再核一遍（桌面启动自己也会改配置）。
4. **可重复的后处理交给钩子。** 钩子在"更新完、DSH 还没重新打开"时执行——此刻没有任何进程占着 `app.asar`，正是打本地补丁的唯一窗口。

## 它**不**做什么

写清楚边界，省得你踩坑：

- **不修模型、不补套餐、不补思考档位。** 那些是本仓库明确不管的事。想要就放进 `hooks`，自己维护。
- **不重建任何配置。** 脚本从不用自己的模板覆盖你的 `cordis.patch.yml`。
- **不擅自扩大插件兼容豁免、不改凭据文件。**
- **不碰 `sessions\`、`attachments\`、作品目录。** 备份与还原只针对清单里的那几个配置文件。
- 默认 **版本相同就不重装**——无谓重装是数据事故的主要来源之一。真要重装请显式 `-Force`。

## 为什么官方更新会掉东西（诊断）

四层原因叠在一起，任意一层都能让"看着没问题"的检查通过：

| # | 故障 | 为什么难发现 |
| --- | --- | --- |
| 1 | **更新抹补丁**：官方整包替换 `app.asar`，本地对 `client.js` / `llm-pi-ai` 的修改全部消失 | 补丁脚本若只认退出码，在"已是补丁状态"时会假阳性返回 0 |
| 2 | **思考档位继承**：只有路由名能匹配内置目录的才会自动继承 `reasoningEfforts`，其它路由必须在 profile 里手写，否则没有强度下拉 | 这条规则没写在任何文档里，只能翻源码 |
| 3 | **一处校验失败连带整段失效**：某协议的本地补丁缺失后，该值不再通过配置校验，结果整个 `providers` 统一校验失败，所有套餐一起消失 | 界面只显示"没模型"，日志没什么可查 |
| 4 | **插件版本闸门**：第三方插件的 `engines.dsh` 锁死旧版本范围，新运行时直接不加载，界面也不提示"因版本不符被跳过" | 插件是静默消失的 |

详见 [`docs/为什么官方更新总掉东西.md`](docs/为什么官方更新总掉东西.md)。

## 安装

```powershell
git clone https://github.com/luxueliu/dsh-luxueliu-update.git
cd dsh-luxueliu-update
Copy-Item config.example.json dsh-luxueliu-update.config.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-button.ps1
```

桌面会多出一个「更新 DSH」按钮。不想建按钮，直接双击 `update-dsh.cmd` 一样用。
脚本自动从注册表卸载项读取安装位置，不需要你填路径；**不装任何依赖**（只用系统自带的 Windows PowerShell 5.1）。

## 用法

```powershell
# 体检：只看现状，一个字节都不改
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-luxueliu-update.ps1 -CheckOnly

# 正式更新
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-luxueliu-update.ps1

# 主台没起来时的补救：只把 DSH 拉起来
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-luxueliu-update.ps1 -StartOnly

# 只重跑钩子（例如手动补打本地补丁）
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-luxueliu-update.ps1 -HooksOnly
```

| 开关 | 作用 |
| --- | --- |
| `-CheckOnly` | 只读体检：版本、feed 最新版本、受保护文件、运行状态 |
| `-DryRun` | 走到安装前为止：下载、校验、备份都真做，不关台不安装 |
| `-Force` | 版本相同也重装（同版本内容覆盖，常用于"修复安装"） |
| `-StartOnly` | 只把 DSH 拉起来 |
| `-HooksOnly` | 只按配置跑钩子，不动版本 |
| `-NoRestart` | 更新完不开台 |
| `-Home <路径>` | 手动指定 DSH 用户数据根目录 |
| `-WaitTimeoutSec <秒>` | 等进程退出的超时，默认 120 |

退出码：`0` = 全部通过，`1` = 有问题清单，日志在 `dsh-luxueliu-update.log`。

## 更新流程

```
读官方 feed(nightly.yml)
   → 版本比对：相同就不动
   → 下载并按 size + sha512 校验（本地缓存命中则跳过下载）
   → 备份受保护数据 + 留底 app.asar
   → 关闭 DSH
   → 跑官方 NSIS 安装包（/S /D=原安装目录）
   → 校验版本；装失败就把 app.asar 换回留底那份
   → 跑钩子（此刻台是关的，没有文件锁）
   → 缺数据就从备份还原
   → 启动 DSH
   → 起来后再核一遍数据
   → 清单式总结
```

## 已知限制（说在前面）

- **跨版本升级这条分支的实测量有限。** 作者在 `0.2.1-rc.3` 上完整跑过安装循环（关台 → 官方包退出码 0 → 装完 → 版本校验 → 自动重开，数据 8/8 在位），但当时官方最新版本就是已装版本，所以"版本从 A 跳到 B"要等下一次 nightly 才有真跑机会。目前 `-Force` 走的是同版本重装。
- **不会替你验"模型还在不在"。** 本仓库刻意不碰模型配置；想加模型验收，请写成钩子。
- 依赖官方 feed 的格式（`nightly.yml` 的 `version` / `files.url` / `sha512` / `size`）。若官方改版，脚本会明确报错而不是猜。
- 安装器必须是 NSIS 制作的；若官方换成其它安装技术，`/S` 参数语义会失效，脚本会在"版本没变成目标值"这一步报出来。

## 三个 Windows 上的坑（踩过的，别再踩）

1. **别用 `Start-Process`。** 环境里存在大小写重复的变量（`HTTPS_PROXY` / `https_proxy`）时，PowerShell 5.1 的 `Start-Process` 直接抛异常，命令根本发不出去。本机就遇到了，全程改用 `ProcessStartInfo`。
2. **子进程不能继承你的控制台。** 控制台一关，Windows 给所有附加进程发 `CTRL_CLOSE`，刚起来的 DSH 跟着没。`UseShellExecute` 挡不住，必须 `CreateNoWindow`。
3. **别在 DSH 开着的时候改 `app.asar`。** 必吃 `EPERM`（文件锁），且旧脚本崩了不留报告。打补丁必须在关台之后——这正是钩子的执行时机。

## 目录结构

```
dsh-luxueliu-update.ps1            主脚本（唯一需要的东西）
config.example.json        配置示例：受保护清单 + 钩子槽位
update-dsh.cmd             双击入口
install-button.ps1         在桌面生成按钮
docs/                      为什么掉东西 / 三个坑
```

运行期产生 `downloads\`、`backups\`、`dsh-luxueliu-update.log`，均在仓库内，已在 `.gitignore` 里排除。

## License

MIT。作者信息匿名处理，欢迎随意 fork。插件不联网、不需要个人信息，安全无毒放心使用。
