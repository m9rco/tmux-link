# Tmux Link

[![Build & integration tests](https://github.com/m9rco/tmux-link/actions/workflows/build.yml/badge.svg)](https://github.com/m9rco/tmux-link/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/m9rco/tmux-link)](https://github.com/m9rco/tmux-link/releases/latest)
![Linux](https://img.shields.io/badge/Linux-x86__64%20%7C%20ARM64-333333?logo=linux)
![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon%20%7C%20Intel-333333?logo=apple)
![iOS](https://img.shields.io/badge/iOS-16%2B-333333?logo=apple)

用 iPhone 接入内网 Linux 或 macOS 上已经运行的 tmux。内网机器通过出站 WSS 配对并保持连接，手机通过中心访问各机器。文中 `center.example.com` 是示例域名，部署时请替换成自己的公网中心地址。SSH 会话在手机与内网主机之间独立加密和认证，中心转发密文。

```text
iPhone ── SSH over WSS ──► public center ◄── outbound WSS ── Linux / Mac
                                                           │ localhost SSH
                                                           ▼
                                                          tmux
```

首页保存多台客户端。点客户端读取该账号的会话，点名称进入终端，返回会话列表即可切换；后台的 tmux 会话继续运行。每台客户端独立配置入口、用户名与 SSH 指纹。长按客户端可编辑，左滑可删除。首次升级会载入之前保存的连接。旧版 agent 支持在会话列表中选择「打开兼容终端」。

**分析待决问题。** 在客户端的会话列表点「查看待答问题」，选中最多六个会话。手机经现有 SSH 连接只读获取每个会话当前活动窗格的画面。先预览，再选择发给当前模型服务的会话。结果按会话列出正在等你回答的问题、屏幕原文、候选答复和各自取舍。有足够依据时会标出推荐答复及理由。可以复制答复并回到原终端处理。API Key 保存在 iPhone 钥匙串。

批量读取请在主机安装 v0.4.5 或更高版本的 agent。也可以在已打开的终端展开右侧快捷栏，点「决策」直接分析当前画面，这条路径兼容旧版 agent。

iOS 0.4.6（Build 37）和 v0.4.6 节点支持在 Linux 或 Mac 上先筛选历史。批量读取时，节点扫描活动窗格最近最多 5000 个历史屏幕行，按 tmux 的软换行标记还原长行，优先保留决策原因、目标、约束、失败线索及近期输出。选出的原文按时间排序，与当前屏幕分开传输。历史摘录上限为 320 个逻辑行、32 KiB，当前屏幕上限为 256 个逻辑行、32 KiB。手机预览会提示历史是否经过筛选，筛选时会显示节点实际扫描的行数。发送给模型的决策摘要仍限制在每会话 4 KiB。备用屏幕只读取当前画面。旧版手机和 v0.4.5 节点均可继续使用原有摘录。

可在节点运行 `tmux-link-agent snapshot 0` 查看同一份 JSON（将 `0` 换成会话编号）。`historyRowsScanned` 是实际读取的历史屏幕行数。若颜色和样式使一次原始读取超过 16 MiB，节点会缩小回看范围再读取。`historyCompacted` 表示节点已筛选历史，`historyTruncated` 表示 tmux 中还有更早的历史超出读取窗口。可用 `tmux display-message -p '#{history_size}/#{history_limit}'` 查看当前窗格已保留的行数和容量。如需为新窗格保留足够的历史，在 tmux 配置中设置 `set -g history-limit 5000` 或更高。

### 会话托管

在手机会话列表点「托管」，选择模式和风格，再启用这个会话。托管要求节点支持协议 v2（v0.5.1 起）。iOS 0.5.4 起，首页右上角「… → 模型服务」可切换 DeepSeek、OpenAI，或添加兼容 Chat Completions 的 HTTPS 中转站。配置中转站时填写服务地址（含服务商指定的路径，如 `/v1`）、模型 ID 与该服务的密钥。托管和手动分析共用当前服务。默认选择 DeepSeek，升级后可继续使用原先保存在 iPhone 钥匙串的密钥。

托管需要服务在响应中返回真实 token 用量，可以是 `usage.total_tokens`，也可以同时提供 `prompt_tokens` 和 `completion_tokens`。手动分析可以使用省略用量的中转站。

已配对的 Linux 或 Mac 节点只需以运行 tmux 的用户更新一次。

```sh
curl -fsSL https://github.com/m9rco/tmux-link/releases/download/v0.5.5/install.sh | sh -s -- --version v0.5.5
```

| 模式 | 会话等待回答时如何处理 |
| --- | --- |
| 仅记录 | 记录候选、推荐理由或回复草稿，供你决定。 |
| 低风险菜单 | 在受支持的前台应用上，界面明确说明按数字即可提交，并且所有选项都属于已识别的显示格式、语言或主题时，可以自动代选。 |
| 协助回复 | 另外支持选择应用列出的固定回复，如「请用简体中文回复。」。开放式问题会生成可复制的回复草稿，等你回终端发送。 |

风格独立于模式。**谨慎**倾向于在证据不足时追问，**均衡**比较选项并给出取舍，**简洁**优先用一句话给结论。需要额外按回车、涉及执行命令、授权、发布或删除的菜单均交给人确认。自动按键还要求前台应用直接占用当前 tmux 窗格，且提交瞬间仍是同一画面。从普通 shell 启动、退出后会回到 shell 的应用可获得建议与草稿。在新的专用窗格中可用 `exec codemaker` 启动，已有会话可继续按原方式使用。

Tmux Link 在手机前台时轮询本机启用的会话。节点经加密 SSH 发送筛选后的问题、候选和短记忆。手机直接请求模型，节点在接收结果时复核窗格身份和当前画面，记录选择与理由。短暂切到其他 App 时，iOS 可允许已经发出的模型请求收尾，待返回前台后再提交仍有效的结果。系统收回后台时间或锁定受保护数据时会取消进行中的请求。每个会话滚动 24 小时最多领取 12 次分析任务，节点保存最近 64 条记录与最多 480 字的短记忆。

在托管记录里可以标记某条选择「偏好」或「避免」，也可把自己的取舍理由保存为通用原则，例如「先用一个样本验证，通过后再扩大范围」。示例只在同一节点、问题和可选回复匹配时使用；通用原则适用于其他问题。个人偏好保存在这部 iPhone，支持查看、修改和删除。每次托管最多附带两条匹配示例，与本次分析共用一次模型请求。

切回终端时优先沿用原 SSH 连接。若 iOS 挂起 App 期间链路失效，手机会核对已打开的命名会话再重连，也可以点「重连」手动恢复。远端 tmux 会话仍在节点上运行。会话列表支持按名称或目录搜索、下拉刷新；刷新失败时保留上次读到的列表。

iOS 与节点均更新到 v0.5.5 后，会话列表用小转圈显示当前窗格正在处理任务，或在连续两次观察之间有新输出。明确显示等待选择或回复时停止转圈。打开终端或将 App 切到后台时暂停列表轮询。节点在本地判断状态，列表只传会话元数据和活动标记，无需调用模型。

从 v0.5.0 升级后，请在手机重新启用需要托管的会话。曾在旧版节点成功保存的密钥文件 `~/.config/tmux-link/managed/api-key` 可在手机配置完成后自行移除。

### 读取已有 CodeMaker 对话

CodeMaker 全屏运行时通常使用 tmux 的备用屏幕。如果当前只有 `esc interrupt`、模型统计和一截命令，更早的对话需要从 CodeMaker 自己的会话记录读取。v0.4.7 起，在节点上打开另一个 shell，以运行 CodeMaker 的用户执行下面两行。示例中的 `1` 是正在运行 CodeMaker 的 tmux 会话编号。

```sh
~/.local/bin/tmux-link-agent bind-session 1
~/.local/bin/tmux-link-agent snapshot 1
```

第一条命令从 CodeMaker 的已有会话列表中让你选一次。已知应用会话 ID 时也可执行 `tmux-link-agent bind-session 1 ses_…`。每次读取会重新调用同一个 CodeMaker 程序导出已绑定的 ID。快照中的 `applicationContext.messages[0]` 是最近一条入选的可见消息，更早的消息排在后面。每条消息内部保留自然阅读顺序。节点最多返回 32 条、合计 32 KiB 的用户与助手正文，工具参数、内部推理及附件不参与摘录。备用屏幕的 `historyRowsScanned` 仍为 0。

如果能列出会话，但绑定时遇到 `invalid CodeMaker session export` 或 `CodeMaker command failed`，请将 Linux 或 Mac 节点更新到 v0.4.9，再用选中的会话 ID 重试。节点通过标准输出管道接收导出。只有 CLI 成功退出、但 JSON 在中途截断时，才用匿名文件重试一次。64 MiB 上限只用于导出内容，CodeMaker 的 SQLite 数据库和日志沿用节点原有的限制。绑定失败时命令会显示退出码、信号或 JSON 出错位置。iOS Build 38 可直接读取新版节点。

iOS 0.4.7（Build 38）的预览显示来源、角色和最近消息。识别到 CodeMaker 的执行状态栏时，预览会标明应用仍在运行。在同一个 CodeMaker 进程内切换对话时，请重新绑定。运行 `tmux-link-agent unbind-session 1` 可解除绑定。主机持久保存绑定信息，导出的对话仅在本次读取时处理。

iOS 0.4.5（Build 35）起，手机在本地过滤常见凭据、输入框边线、模型状态栏和重复进度，按当前问题、原因、目标、约束与相关步骤组织摘录。每个会话发送给 DeepSeek 的结构化内容最多 4 KiB，当前画面和历史保留来源。预览展示本次实际发送的内容。确认某个编号步骤时，答复围绕同意或暂缓该步。

终端显示交互菜单时，预览直接展示可识别的单选或多选、选项原文、光标和勾选状态，以及屏幕给出的选择和提交方式。终端未说明的按键不会补写。选择和提交由用户回原终端操作。

收起键盘后，终端网格从屏幕顶边延伸到底边。带灵动岛的 iPhone 竖屏时，连接状态点和延迟紧贴岛的右侧，打字时也能看到，点按可查看详情。延迟来自当前 SSH 会话到内网主机的往返测量。横屏或其他机型的状态显示在右上角。切到其他 App 后，开启实时活动的 iPhone 也可在系统灵动岛上查看连接状态。锁屏和灵动岛只展示连接信息。从左边缘向右滑，或在正文中向左滑，即可返回会话列表。

从终端右边缘向左滑可拉出快捷键，包括 Esc、PgUp、PgDn、Tab、Ctrl-C、Ctrl-B、方向键和回车。键盘弹出或横屏时可以滚动按键列。点正文或在按键列上向右滑即可收起，远端终端保持相同行列数。

点终端打开英文键盘。Shift 切换大小写，123 切换数字和符号。键盘上方有 Esc、Tab、Ctrl-C、Ctrl-B 和 ← ↑ ↓ →。在 shell 里按 ↑、↓ 可以翻看命令历史，在终端菜单里可以上下移动选项。

iOS Build 43 和 v0.5.3 节点支持 Agent 快捷回复。当前窗格的前台程序被识别为交互式 Agent 时，键盘符号行和右侧快捷栏会出现 **Agent**。点开可选 `Proceed`、`Keep going`、`Follow up on this`、`Ack` 等英文回复，以及 `/compact`、`/models` 和 `/help`。选中的文字插入当前光标处，可以继续编辑，按回车发送。命令的可用性取决于会话中运行的 CLI。

双击光标所在的输入行可选中当前可见输入，继续键入或粘贴可替换选区。长按光标行后点「粘贴」，文本会通过终端当前的粘贴模式送到远端。长按输出可拖动系统选区手柄，再点「复制」。会话列表中也可长按名称复制。

在终端正文向下拖，可以翻回上方被挤出屏幕的输出；向上拖回到更新的内容。普通 shell 中可以直接回看 tmux 保存的窗格历史，包括手机连接前的 `git status` 输出。新版 agent 在滑回底部时自动恢复输入，并支持自定义 tmux 前缀。全屏程序支持鼠标时接收滚轮，否则新版 agent 将翻页键交给当前程序。右侧快捷键也可以手动翻页。

旧版 agent 的命名会话在关闭鼠标时按默认 tmux 前缀 `Ctrl-B` 进入回看，按 `q` 退出；自定义前缀可升级 agent 或使用自己的绑定。

如果中文在手机上变成下划线，更新内网机器的 `tmux-link-agent`，再从手机重新进入原会话。新版 agent 用 `tmux -u` 读取会话列表并接入终端，即使 SSH 登录环境没有设置 UTF-8 locale，也能传递原字符。

## 一键安装

在内网 Linux 或 Mac 上执行，无需 GitHub 登录。

```sh
curl -fsSL https://github.com/m9rco/tmux-link/releases/latest/download/install.sh | sh
```

默认只安装客户端 `tmux-link-agent`。普通用户安装到 `~/.local/bin`，root 安装到 `/usr/local/bin`。把安装目录加入 PATH，已有终端可以直接执行 `export PATH="$HOME/.local/bin:$PATH"`。

已配对的 Linux 或 Mac 以原安装用户重新运行上面的命令即可升级，再用 `tmux-link-agent --version` 核对安装版本。下次从手机读取会话时会使用新的节点程序，已有配对和 tmux 会话可继续使用。

连接一台新机器时，以运行 tmux 的用户执行下面的安装配对命令。机器需要已运行的 OpenSSH 服务和 tmux。

```sh
curl -fsSL https://github.com/m9rco/tmux-link/releases/latest/download/install.sh | sh -s -- --connect center.example.com
```

已安装客户端时，直接运行 `~/.local/bin/tmux-link-agent pair --center center.example.com`。命令会检测当前 SSH 登录端口（本地运行默认 22），与手机使用同一套 SSH 协商规则取得主机指纹，支持 Ed25519、ECDSA 和 RSA-SHA2 主机密钥，打印十分钟有效的配对链接并等待确认。用已登记中心设备证书的 iPhone 打开或粘贴链接，核对机器上显示的指纹，点「确认配对并连接」。客户端自动将手机公钥加入当前用户的受限 `~/.ssh/authorized_keys`，建立四条出站 WSS 备用连接，并保存用户后台服务。手机随即进入会话列表。中心自动登记机器和批准它的手机。

Linux 使用 systemd 用户服务，macOS 使用登录用户的 LaunchAgent。Linux 需要退出登录后仍在线时，由管理员运行 `sudo loginctl enable-linger 用户名`。缺少用户服务管理器时，命令会在当前终端维持连接，并输出手动恢复命令。自定义本机 SSH 端口可在 `pair` 后加 `--ssh-port 2201`。配对通过 443 出站，适用于动态内网 IP。机器的连接令牌保存在当前用户权限为 700 的 `~/.config/tmux-link/paired/` 目录中。

公网中心安装并附带 OpenSSH、tmux 依赖（Debian/Ubuntu）时执行下方命令。

```sh
curl -fsSL https://github.com/m9rco/tmux-link/releases/latest/download/install.sh | sudo sh -s -- --role center --with-deps
```

需要完整安装两种角色时选择 `--role both`。安装前先核对脚本，可先下载到文件再执行。Linux 需要 curl、tar 和 sha256sum。macOS 使用系统 curl、tar 和 shasum。Mac 上可加 `--with-deps` 用 Homebrew 安装 tmux，执行时使用普通用户。

```sh
# 固定版本和自定义安装位置
curl -fsSL https://github.com/m9rco/tmux-link/releases/download/v0.1.3/install.sh | sh -s -- --version v0.1.3 --prefix "$HOME/.local"
```

可用 `--from-dir /path/to/downloads` 从包含归档和 SHA256SUMS 的本地目录离线安装，也可用 `--download-base-url https://mirror.example.com/release` 指定包含同名归档和 SHA256SUMS 的 HTTPS 镜像。私有 fork 的下载可设置 `GH_TOKEN` 或 `GITHUB_TOKEN` 并安装 GitHub CLI。

脚本自动识别 Linux / macOS 与 x86_64 / ARM64，下载失败会重试，SHA256 校验通过后安装。二进制升级使用同文件系统重命名，已运行进程继续使用原版本。安装命令使用 tmux-link-agent / tmux-link-center 命名，避免覆盖其他工具的 agent 命令。部署模板和指南安装到 `PREFIX/share/tmux-link`。自定义安装位置时修改 systemd 模板中的可执行文件路径，按下方说明完成公钥和主机配对后启用服务。

## 把 Linux 或 Mac 客户端导入手机

在已接入中心的机器上，以 tmux 所属用户生成链接。将域名和路由替换为该机器在中心的配置。主客户端的默认路由是 `primary`。

首次接入优先运行上一节的 `pair` 命令完成自动配对。以下 `import-link` 命令适用于已经建立 SSH 反向隧道并登记中心路由的手动部署。

```sh
tmux-link-agent import-link --center center.example.com --route build --name "构建机"
```

在 iPhone 点开收到的链接，或复制整条链接后在 Tmux Link 客户端列表点「导入客户端配置」旁的粘贴按钮。核对主机和指纹后点「保存」，即可进入该机器的会话列表。在 Mac 上给命令追加 `| pbcopy` 可直接复制。已保存的客户端也可长按「复制客户端配置」。

命令默认使用当前用户名和 443 端口。Linux 默认读取 `/etc/tmux-link/host_ed25519.pub`，macOS 默认读取 `/etc/ssh/ssh_host_ed25519_key.pub`。自定义部署可用 `--host-key` 指定内网 sshd 的实际公钥，并用 `--user`、`--port` 指定用户名和公网 WSS 端口。链接携带公开的连接参数和 SSH 指纹。首次接入新机器时，需先按下方部署步骤建立隧道、授权手机 SSH 公钥，并在中心给手机证书授权该路由；导入后会使用手机已有的密钥和证书。

## GitHub 构建与发布

每次推送 main 或创建 PR 都运行 Rust 格式与 Clippy 检查、安装脚本测试、TCP 与 WebSocket 两种传输的真实 Linux tmux 集成测试，构建 Linux、macOS 的 x86_64 / ARM64 和未签名的 iOS 设备及模拟器 App。构建包在 Actions 页面的 Artifacts 中下载。

推送 `v*` 标签且全部检查通过后，流水线自动创建 GitHub Release，附带 Linux 安装包、两个 iOS 包、安装脚本和 SHA256SUMS。iOS 设备包需要使用自己的 Apple 签名安装。

## 构建

Linux 需要 Rust、OpenSSH 和 tmux。在项目根目录执行以下命令，然后将 `center` 安装到公网服务器，将 `agent` 安装到内网机器的 `/usr/local/bin/`。

```sh
cargo build --release --locked -p tmux-link --bins
```

iOS 客户端使用 Rust SSH 核心、UIKit、Keychain 和随 App 打包的 xterm.js 6.0.0 / addon-fit 0.11.0。Apple Silicon Mac 需要完整 Xcode 和 rustup。运行 `./scripts/build-ios.sh device` 生成未签名设备包，模拟器使用 `./scripts/build-ios.sh simulator`。要装到手机，先构建设备包，再打开 `ios/TmuxLink.xcodeproj`，在 Signing & Capabilities 选择自己的 Team 和可用的 bundle ID，选择 iPhone 后 Run。首次打开时点「复制本机 SSH 公钥」。若重新生成工程，运行 `cd ios && xcodegen generate`。

## 公网中心

启用自动配对时，在下面的中心配置基础上完成这些设置。

1. 将 `deploy/nginx-tmux-link-broker-proxy.conf` 安装为 `/etc/nginx/tmux-link/broker-proxy.conf`，更新 nginx 的设备授权 map 和 HTTPS location 模板。配对确认和会话入口要求当前手机证书拥有 `primary` 授权，中心进一步将每台机器绑定到批准它的证书。注册和机器隧道入口用随机令牌校验，并通过 nginx 限速。
2. 在服务启动参数末尾添加 `--pairing-dir=/var/lib/tmux-link/paired`。用中心运行账号创建该目录，权限 700。如果启用了 `ProtectSystem=strict`，为服务添加 `ReadWritePaths=/var/lib/tmux-link/paired`。服务必须监听回环地址，由 nginx 覆盖传入的 `X-Tmux-Device` 请求头。
3. 用 `nginx -t` 验证后重载 nginx，重启 center。中心按权限 600 持久化登记状态，重启后客户端会自动重连。需要撤销某台机器时，先停止它的用户服务，在中心停止服务并备份、移除 `hosts.json` 中该机器记录，再启动中心。手机证书撤权沿用下方授权文件和 nginx 重载流程。

1. 为隧道创建专用非 root 用户 `tmuxrelay`，给它配置仅用于隧道的 SSH 公钥，作为该用户执行 `install -d -m 700 ~/link`。公网中心 SSH 的授权密钥是 **Linux 隧道公钥**。手机公钥只交给内网 Linux。
2. 将 `deploy/center-sshd-match.conf` 追加到公网 sshd 配置末尾，用 `sshd -t` 检查后 reload。该用户可以创建远端 Unix socket，无法开启 shell 或 TCP 转发。确保其家目录为专用目录。
3. 将 `deploy/tmux-link-center.service` 安装到 `/etc/systemd/system/`，执行 `systemctl daemon-reload && systemctl enable --now tmux-link-center`。示例使用 `127.0.0.1:7682` 接收 WebSocket，已有 SSH 端口接收内网隧道。按下一节配置 nginx 的设备认证。公网手机入口使用 443，内网隧道使用 22。

### 设备证书和路由授权

HTTPS 入口在 WebSocket 升级前验证设备证书。首次打开 App 后，通过已配对并受信任的 iPhone 获取 `Documents/tmux-link-device-public.pem`。这是手机生成的 P-256 公钥，用于 mTLS，与 tmux 主机上的 SSH 公钥分别授权。下例在管理 Mac 上运行，使用 Python 3 和 OpenSSL 3 或更高版本。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVICE_UDID=你的设备标识
CA_DIR="$HOME/.tmux-link-device-ca"
DEVICE_DIR=$(mktemp -d)
python3 deploy/device-cert.py init "$CA_DIR"  # 每个管理域首次执行一次
xcrun devicectl device copy from --device "$DEVICE_UDID" --domain-type appDataContainer \
  --domain-identifier dev.tmuxlink.mobile --source Documents/tmux-link-device-public.pem \
  --destination "$DEVICE_DIR/device.pub"
python3 deploy/device-cert.py issue "$CA_DIR" phone "$DEVICE_DIR/device.pub" "$DEVICE_DIR/device.cer"
python3 deploy/device-cert.py grants "$DEVICE_DIR/device.cer" primary > "$DEVICE_DIR/phone.map"
python3 -c 'import base64,json,sys; print(json.dumps({"host":sys.argv[1],"certificate":base64.b64encode(open(sys.argv[2],"rb").read()).decode()}))' \
  center.example.com "$DEVICE_DIR/device.cer" > "$DEVICE_DIR/enrollment.json"
xcrun devicectl device copy to --device "$DEVICE_UDID" --domain-type appDataContainer \
  --domain-identifier dev.tmuxlink.mobile --source "$DEVICE_DIR/enrollment.json" \
  --destination Documents/tmux-link-enrollment.json
```

将示例域名替换为手机配置的中心域名，重新打开 App 导入证书。设备证书有效期为一年，期满前可为同一手机公钥重新签发。先加入新证书的路由授权，验证连接后移除旧证书的授权。Personal Team 的 App 续签与设备证书续期各自进行。

在中心创建 `/etc/nginx/tmux-link/`，复制 **公开 CA 证书** 到该目录下的 `device-ca.pem`；管理 Mac 保管 `device-ca.key`，可做加密离线备份。将每台手机的 `phone.map` 条目合并进 `/etc/nginx/tmux-link/authorized-routes.map`。上例授权 `primary`，涵盖 `/tmux-link` 与 `/tmux-link/primary`；需要访问第二台机器时，可在 `grants` 命令末尾追加其路由名。

把 `deploy/nginx-tmux-link-map.conf` 安装到 nginx 的 `http` 配置上下文（通常为 `/etc/nginx/conf.d/tmux-link-mtls-map.conf`），再将 `deploy/nginx-tmux-link.conf` 放入中心域名的 HTTPS `server` 块，替换已有的终端 location。执行 `nginx -t` 和 `systemctl reload nginx`。该虚拟主机会在 TLS 握手中请求客户端证书，终端路由要求证书和授权同时有效，同域的其他 HTTP 服务仍可接受无证书连接。公网仅暴露受保护的 WSS 入口；Rust center 的后端端口绑定在回环地址。

丢失手机时，从授权文件移除该证书序列号的全部条目并校验、重载 nginx。撤权针对新连接，已升级的 WebSocket 可以继续运行。要立即断开现有的所有终端连接，执行 `systemctl restart tmux-link-center`；内网 tmux 会话继续运行，其余授权设备可以重连。也应撤销内网主机上该手机的 SSH 公钥。首次将旧公网入口切换为 mTLS 时同样可用这一操作结束切换前的连接。

## 内网 Linux

将模板中的 `alice` 改为拥有 tmux 会话的实际非 root 用户。在该账号下运行 `tmux ls` 应该能看到目标会话。默认使用该账号的默认 tmux socket。

1. 为隧道生成独立 Ed25519 密钥，在该用户的 `~/.ssh/config` 写入下面的别名。通过已有可信管理连接核对中心的主机公钥，加入该用户的 `known_hosts`。先完成中心侧公钥授权。
2. 以管理员身份运行下方初始化命令，安装独立的 sshd 配置及**手机公钥**。`phone.keys` 应由 root 持有、可供登录用户读取。将输出的 **SHA256 指纹**通过可信渠道填入手机。
3. 安装 `deploy/tmux-link-inner.service` 和 `deploy/tmux-link-tunnel.service` 到 `/etc/systemd/system/`，更新隧道服务中的用户名。执行 `systemctl daemon-reload && systemctl enable --now tmux-link-inner tmux-link-tunnel`。隧道断线时由 systemd 重启。

```sshconfig
# 把示例域名换成自己的公网中心地址
Host tmux-center
    HostName center.example.com
    User tmuxrelay
    IdentityFile ~/.ssh/tmux-link-relay
    IdentitiesOnly yes
```

```sh
# 以 tmux 用户身份生成一次，授权 .pub 到中心 tmuxrelay 账号
ssh-keygen -t ed25519 -f ~/.ssh/tmux-link-relay -N ''
# 以下以 root 执行，phone.pub 为从手机复制的完整公钥
install -d -m 755 /etc/tmux-link /run/sshd
ssh-keygen -t ed25519 -f /etc/tmux-link/host_ed25519 -N ''
install -m 644 phone.pub /etc/tmux-link/phone.keys
install -m 644 deploy/inner-sshd.conf /etc/tmux-link/inner-sshd.conf
# 在 inner-sshd.conf 中替换 AllowUsers alice
/usr/sbin/sshd -t -f /etc/tmux-link/inner-sshd.conf
ssh-keygen -lf /etc/tmux-link/host_ed25519.pub
```

手机填写公网中心地址 `center.example.com`、端口 443、内网用户名和刚核对的内网主机指纹，保存客户端后点选会话。若入口不通，依次查看两端 systemd 日志、中心 socket 是否存在、内网监听 2201 的服务及 tmux 所属账号。认证和连接日志保留在系统 SSH 日志中。

## 内网 macOS

1. 安装客户端与 tmux，在系统设置 → 通用 → 共享中开启「远程登录」，只允许需要的用户。运行 `tmux new -s work` 创建会话。Mac 客户端使用系统 OpenSSH，默认转发本机端口 22。
2. 创建 `~/.config/tmux-link`（权限 700），用 `ssh-keygen -t ed25519 -f ~/.config/tmux-link/tunnel -N ''` 生成独立隧道密钥，将公钥授权给公网中心的 tmuxrelay 用户。
3. 在 `~/.config/tmux-link/ssh_config` 中写入上方的 `Host tmux-center` 配置，IdentityFile 改为该隧道密钥的绝对路径，添加已通过可信连接核对的公网中心主机公钥到 known_hosts，并指定 `UserKnownHostsFile` 和 `StrictHostKeyChecking yes`。
4. 将手机公钥加到 Mac 的 `~/.ssh/authorized_keys`，使用下面的受限格式。替换用户名及安装路径。主机指纹来自 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`，在手机中核对。
5. 复制 `deploy/dev.tmuxlink.tunnel.plist` 到 `~/Library/LaunchAgents/`，替换 YOUR_USER、SSH 配置路径及远端 socket。运行 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.tmuxlink.tunnel.plist`。登录用户会话后保持隧道在线，退出登录和机器睡眠会断开。

```text
restrict,pty,command="/usr/bin/env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin /Users/YOUR_USER/.local/bin/tmux-link-agent attach" ssh-ed25519 PHONE_PUBLIC_KEY tmux-link-ios
```

手动验证出站隧道可运行下方命令。`TMUX_LINK_SSH_CONFIG` 指定独立配置文件，客户端也支持默认的 ~/.ssh/config。同一个 center 可以转发到多台机器，各自使用独立的 socket 和 SSH 主机指纹。

```sh
TMUX_LINK_SSH_CONFIG="$HOME/.config/tmux-link/ssh_config" tmux-link-agent tunnel tmux-center /home/tmuxrelay/link/primary.sock 22
```

端口 443 默认使用 WSS，内网 SSH 主机指纹仍需独立核对。原有 TCP 模式可通过其他端口使用；中心启动时省略 `--websocket` 即可保持旧版传输。

## 在同一中心接入第二台客户端

主客户端继续使用 `/tmux-link`，也可使用 `/tmux-link/primary`。第二台机器将自己的 SSH 端口转发到单独的 socket，例如 `/home/tmuxrelay/link/build.sock`。在 center 的启动参数中显式登记该名称和路径，重新启动服务并载入新版 nginx 模板。

```sh
tmux-link-center 127.0.0.1:7682 /home/tmuxrelay/link/primary.sock --websocket build=/home/tmuxrelay/link/build.sock
```

在 iPhone 点「添加客户端」，填入第二台机器的名称、用户名、SSH 指纹，以及客户端路由 `build`；中心仍填 `center.example.com`。可以追加更多 `NAME=/absolute/socket` 参数。路由名区分大小写，最长 64 位，只允许英文字母、数字、下划线和短横线。中心拒绝未登记的路径。手机通过加密 SSH 请求读取和选择会话。

## 安全与性能边界

- 主机指纹匹配且手机私钥通过 SSH 签名认证后才会启动 `agent attach`。手机私钥保存在仅本设备解锁时可读的 Keychain 项中。更换手机时重新授权公钥。删除 `phone.keys` 中对应行会拒绝后续登录，已连接的设备需要另行断开其 SSH 会话。
- 中心可以看到端点、连接时间、字节量，也可中断流量。SSH 保护会话内容。手机、Linux、tmux 插件和同用户进程仍是信任边界。进入 shell 或 AI CLI 后，操作者拥有该 主机账号自身的执行权限。
- 中心用 Tokio 双向转发，握手与活动请求最多 32 条并发，自动配对最多登记 128 台机器，每台保留最多四条备用通道，未安装录屏或会话内容日志。终端按字节处理，输入和输出分别推进，输出随渲染进度施加背压。移动网络的实际延迟取决于手机、中心与 Linux 三者之间的链路。

## 验证

| 测试 | 验证内容 |
|---|---|
| 安装脚本 | 离线安装、角色选择、校验失败拒绝写入 |
| HTTPS 下载集成 | 临时 TLS 服务执行真实 `curl &#124; sh`，验证默认客户端安装、升级和损坏包拒绝 |
| mTLS 入口集成 | 临时 nginx 验证无证书、外部 CA、未授权设备和错路由被拒，授权设备升级 WebSocket，撤权后新连接被拒 |
| tmux 集成 | 真实 Linux / OpenSSH 隧道，验证错误指纹、未授权密钥、分片输入、尺寸调整和断线重连 |
| 输入协议 | 超大帧和未知帧被拒绝并断开连接 |
| 发布包 | x86_64 和 ARM64 构建包安装后执行实际二进制 |
| iOS | 设备与 ARM64 模拟器构建，校验 IPA 内嵌的实时活动扩展，并在模拟器通过真实 SSH 和 tmux 测量首屏与 100 次按键回显 |

输入缓冲区在同一连接中复用，减少连续按键和粘贴时的重复分配。SSH 即使遇到输入协议错误也会发起断开，关闭等待上限为 5 秒。

读取会话列表成功后，手机会将最近使用的 SSH 连接保留 20 秒。打开相同主机的会话时可以复用这条连接，主机指纹、路由、用户和设备凭据都要匹配。终端会优先用手机实测的行列数打开远程 PTY。

每次推送和 PR 的 CI 在 `simulator-performance` 构建产物中保存一份 JSON。它记录打开会话到 xterm 首次显示远端标记的时间，以及内置键盘发出按键到 xterm 显示远端回显的中位数和 P95。CI 使用隔离的本地 SSH/tmux，适合比较客户端版本。下方真机测试会通过实际中继生成同样的指标，保存在 XCTest 的 `terminal-performance.json` 附件中。两组数据应分别比较。

`cargo fmt --all -- --check` 和 `cargo clippy --workspace --all-targets -- -D warnings` 检查 Rust 代码。`scripts/e2e-linux.sh` 使用临时 Docker 容器和临时密钥，通过 iOS 同一 Rust FFI 入口访问真实 Linux tmux，检查错误指纹、未授权设备密钥、会话选择、输入回显、窗口尺寸和重连后的 shell 状态。Apple Silicon 上默认测试目标为 x86_64 Linux musl，Docker 需要支持运行 amd64 镜像。终端组件、字符数据和字体的许可证位于 `ios/assets/`。


## iPhone 个人团队与真机测试

在 Xcode 的 Apple Accounts 登录账号并选择 Personal Team。将 Team ID 写入本机的 `ios/LocalSigning.xcconfig`，该文件已加入 Git 忽略列表，内容为 `DEVELOPMENT_TEAM = 你的TeamID`。App 和测试目标使用自动签名，CI 使用未签名构建。

Mac 出站隧道在线后，用 USB 连接并解锁 iPhone，在普通用户终端执行下方命令。首次签名可能需要 macOS 钥匙串授权；首次启动若提示不受信任，在 iPhone 的「设置 → 通用 → VPN 与设备管理」确认自己的开发者账号。

```sh
TMUX_LINK_E2E_HOST=center.example.com scripts/test-ios-device.sh YOUR_DEVICE_ID --pair-local-mac
```

脚本构建并安装 Debug App，读取手机导出的 SSH **公钥**，以受限的 `tmux-link-agent attach` 命令授权到当前 Mac，再创建独立临时 tmux 会话。真机测试从手机 Keychain 读取自己的私钥，通过公网中心的 WSS 入口发送命令并断开重连，校验远端 shell 状态保留。测试结束会删除临时会话，并在 `target/iphone-e2e-*.xcresult` 保留结果。手机私钥始终位于本设备 Keychain。测试用本次构建的 Mac agent 生成导入链接，在独立的测试配置存储中解析并保存，再用手机本机已登记的 mTLS 证书验证会话连接。

## 个人签名自动维护

装有 Xcode 的 Mac 可以为已配对的 iPhone 定期检查签名。先执行上方真机测试，再在普通用户终端运行：

```sh
scripts/renew-ios.py install YOUR_DEVICE_UDID
scripts/renew-ios.py status
```

安装命令会保存当前 iOS 源码和已编译的 Rust 库快照，签名并覆盖安装 Release 版，保留原 Bundle ID 和 Keychain。首次用 USB 在 Xcode 配对后，保持 Mac 已登录且未休眠。iPhone 与 Mac 接入能互相访问的同一局域网时，Xcode 可通过 Wi-Fi 安装。launchd 每五分钟检查一次，按主 App 和实时活动扩展两份描述文件中较早的到期时间，提前三天开始探测已配对的 iPhone，连通后请求 Xcode 更新描述文件。如果设备离线或 Apple 暂未延长有效期，任务会在下次检查时重试。只有安装成功才记录新有效期。更新项目后重新运行安装命令以替换快照。日志在 `~/Library/Application Support/TmuxLink/Renewal/refresh.log`。运行 `scripts/renew-ios.py uninstall` 可停用任务。

手机暂时不在同一网络时，完成构建后可运行 `scripts/renew-ios.py queue 设备UDID`。Mac 会先签名并核对设备和扩展，再由同一个续签任务每五分钟检查一次。手机连回可互通的 Wi-Fi 或接上 USB 且系统允许安装时，任务会安装排队的版本，即使旧版签名还有效。运行 `scripts/renew-ios.py status` 可区分待安装版本和上次成功安装记录。

使用手机端 SideStore 时，从 Release 下载 `TmuxLink.ipa`，按 [SideStore 官方安装指南](https://docs.sidestore.io/docs/installation/install.html) 配置，在 My Apps 导入 IPA 并刷新。SideStore 刷新需要 Wi-Fi 和 LocalDevVPN。建议同一安装只选一种签名管理方式。免费个人团队描述文件的有效期为七天，见 [Apple 开发者账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account/)。
