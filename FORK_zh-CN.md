# 自用 Windows 版本

仓库：https://github.com/htt050715/komari-agent

本分支默认关闭 Windows 登录时的 Komari 通知，保留监控、远程终端和文件管理。
如需恢复自动登录通知，添加 `--disable-startup-notification=false`，
或在 JSON 配置中设置 `"disable_startup_notification": false`。
`--show-warning` 仍可手动显示一次通知。

自动更新和版本切换均从 **htt050715/komari-agent** 获取 Release，安装脚本也从该仓库下载。
自动更新保留上游规则：同一个 major.minor 系列内更新，例如 `1.5.12` 更新到 `1.5.13`。
更新不会自动回到官方仓库。

## Windows 安装 / 覆盖升级

推荐下载 [install-komari.cmd](https://ghproxy.05160715.xyz/https://github.com/htt050715/komari-agent/releases/latest/download/install-komari.cmd)，
双击运行并确认管理员权限。只需要这一个文件，无需预装 Go 或 Git。
已有服务时选择覆盖或取消，默认取消；全新安装时按提示填写面板地址和 Token。
脚本校验下载的安装器，并固定使用它所属的 Release 版本。
如下载代理暂时不可用，可使用 [GitHub 直连下载](https://github.com/htt050715/komari-agent/releases/latest/download/install-komari.cmd)。

一键脚本、Windows/Linux 安装器和客户端自动更新默认先走 `https://ghproxy.05160715.xyz`，
网络或 HTTP 错误时回退 GitHub 直连。Windows 安装器与自动更新还会在校验失败时尝试直连，
Windows 安装器必须取得 Release 的 SHA-256，校验通过后才替换旧程序。
客户端版本 API 返回无效 JSON 时也会回退。设置了 `GITHUB_TOKEN` 的客户端请求只走直连，避免令牌泄露到代理。
客户端可用环境变量 `KOMARI_GITHUB_PROXY` 更换代理，显式设置为空可禁用代理；
安装器可用 `--install-ghproxy` 更换代理。NSSM 的非 GitHub 下载不走这个代理。

下载仓库或 Release 中的 `install.ps1`，在 PowerShell 中运行：

```powershell
# 已安装时：选择 1 覆盖升级，选择 2 或直接回车取消。
# 没有传入新的 agent 参数时，保留现有服务参数。
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

# 全新安装：使用面板生成的 endpoint 和 token。
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 --endpoint https://你的面板 --token 你的Token
```

安装脚本会申请管理员权限。默认检查 `%ProgramFiles%\Komari` 和 `komari-agent` 服务。
已有 NSSM 服务安装在其他目录时，自动使用该服务的实际目录；
也可以用 `--install-dir` 和 `--install-service-name` 指定目录及服务名。
检测的是指定服务和安装目录，不会扫描整个硬盘。

发现已有目录或服务后，用户可以选择：

- **覆盖升级**：下载完成后备份旧 EXE，停止服务并替换程序；保留配置文件、
  服务账号、工作目录和环境变量。没有新增 agent 参数时保留原参数；
  如传入新参数，则替换整组启动参数，请同时提供完整的 endpoint、token 等配置。
- **取消**：不下载、不停止服务、不改动已有文件。

启动失败会尝试恢复旧程序、旧参数和原运行状态，备份文件保留在安装目录。
NSSM 服务启动成功不等于面板连接成功，安装后请在面板确认设备在线。

无人值守安装可显式选择 `--install-existing overwrite` 或 `--install-existing cancel`。
没有既有服务但目录内有配置时，脚本保留文件；请用 `--config` 或完整参数指定要加载的配置。

## 构建及验证

```powershell
go test -timeout 60s -skip 'Test(ICMP|TCP|HTTP)Ping' ./...
powershell -NoProfile -File tests/install-windows.test.ps1
powershell -NoProfile -File tests/one-click.test.ps1
powershell -NoProfile -File tests/github-proxy.test.ps1
$env:CGO_ENABLED = '0'
go build -trimpath -ldflags "-s -w -X github.com/komari-monitor/komari-agent/update.CurrentVersion=1.5.13" -o komari-agent-windows-amd64.exe
```

Release 文件名保持 `komari-agent-windows-amd64.exe`、`komari-agent-windows-arm64.exe`、
`komari-agent-windows-386.exe`，用于现有更新器按架构匹配。
未来发布版本须继续包含通知默认值与更新源修改，并使用递增的语义版本号。
上游三个公网 Ping 测试依赖外部站点、IPv6 连通性与原始套接字权限，以上命令排除它们。
本 fork 保留提交构建和 Release 产物构建；快照、Docker 与自动生成发布说明仅手动运行，
避免每次提交额外发布快照或覆盖手写的发布说明。

修改 `install-one-click.ps1` 后，运行 `powershell -NoProfile -File build-one-click.ps1`
重新生成单文件 `install-komari.cmd`。
