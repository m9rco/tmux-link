# Tmux Link

[![Build & integration tests](https://github.com/m9rco/tmux-link/actions/workflows/build.yml/badge.svg)](https://github.com/m9rco/tmux-link/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/m9rco/tmux-link)](https://github.com/m9rco/tmux-link/releases/latest)
![Linux](https://img.shields.io/badge/Linux-x86__64%20%7C%20ARM64-333333?logo=linux)
![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon%20%7C%20Intel-333333?logo=apple)
![iOS](https://img.shields.io/badge/iOS-16%2B-333333?logo=apple)

用 iPhone 接入内网 Linux 或 macOS 上已经运行的 tmux。内网机器主动通过 SSH 反向转发注册私有 Unix socket，手机通过 `wss://bj.lander.work/tmux-link` 接入。SSH 会话在手机与内网主机之间独立加密和认证，中心转发密文。

```text
iPhone ── SSH over WSS ──► bj.lander.work:443/tmux-link
                                      │ HTTPS → loopback center:7682
                                      ▼
                              私有 Unix socket
                                      │ 内网主动建立的 SSH 隧道
                                      ▼
                            Linux / Mac SSH → tmux
```

一个入口对应一个内网用户和一台主机。只有一个会话时自动进入，有多个会话时显示编号供选择。在 iPhone 上可用 Esc、Tab、方向键、Ctrl-C、Ctrl-B 和系统键盘。横竖屏或键盘高度变化会通知远端 PTY 调整行列数。离开连接页面或网络中断后，重新连接即可接回服务端仍在运行的会话。

## 一键安装

在内网 Linux 或 Mac 上执行，无需 GitHub 登录。

```sh
curl -fsSL https://github.com/m9rco/tmux-link/releases/latest/download/install.sh | sh
```

默认只安装客户端 `tmux-link-agent`。普通用户安装到 `~/.local/bin`，root 安装到 `/usr/local/bin`。把安装目录加入 PATH，已有终端可以直接执行 `export PATH="$HOME/.local/bin:$PATH"`。

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

1. 为隧道创建专用非 root 用户 `tmuxrelay`，给它配置仅用于隧道的 SSH 公钥，作为该用户执行 `install -d -m 700 ~/link`。公网中心 SSH 的授权密钥是 **Linux 隧道公钥**。手机公钥只交给内网 Linux。
2. 将 `deploy/center-sshd-match.conf` 追加到公网 sshd 配置末尾，用 `sshd -t` 检查后 reload。该用户可以创建远端 Unix socket，无法开启 shell 或 TCP 转发。确保其家目录为专用目录。
3. 将 `deploy/tmux-link-center.service` 安装到 `/etc/systemd/system/`，执行 `systemctl daemon-reload && systemctl enable --now tmux-link-center`。示例使用127.0.0.1:7682 接收 WebSocket，已有 SSH 端口接收内网隧道。在域名的 HTTPS server 块中 include `deploy/nginx-tmux-link.conf`，运行 `nginx -t` 后 reload。公网手机入口使用 443，内网隧道使用 22。

## 内网 Linux

将模板中的 `alice` 改为拥有 tmux 会话的实际非 root 用户。在该账号下运行 `tmux ls` 应该能看到目标会话。默认使用该账号的默认 tmux socket。

1. 为隧道生成独立 Ed25519 密钥，在该用户的 `~/.ssh/config` 写入下面的别名。通过已有可信管理连接核对中心的主机公钥，加入该用户的 `known_hosts`。先完成中心侧公钥授权。
2. 以管理员身份运行下方初始化命令，安装独立的 sshd 配置及**手机公钥**。`phone.keys` 应由 root 持有、可供登录用户读取。将输出的 **SHA256 指纹**通过可信渠道填入手机。
3. 安装 `deploy/tmux-link-inner.service` 和 `deploy/tmux-link-tunnel.service` 到 `/etc/systemd/system/`，更新隧道服务中的用户名。执行 `systemctl daemon-reload && systemctl enable --now tmux-link-inner tmux-link-tunnel`。隧道断线时由 systemd 重启。

```sshconfig
Host tmux-center
    HostName bj.lander.work
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

手机填写公网中心地址 `bj.lander.work`、端口 443、内网用户名和刚核对的内网主机指纹，点「连接 tmux」。若入口不通，依次查看两端 systemd 日志、中心 socket 是否存在、内网监听 2201 的服务及 tmux 所属账号。认证和连接日志保留在系统 SSH 日志中。

## 内网 macOS

1. 安装客户端与 tmux，在系统设置 → 通用 → 共享中开启「远程登录」，只允许需要的用户。运行 `tmux new -s work` 创建会话。Mac 客户端使用系统 OpenSSH，默认转发本机端口 22。
2. 创建 `~/.config/tmux-link`（权限 700），用 `ssh-keygen -t ed25519 -f ~/.config/tmux-link/tunnel -N ''` 生成独立隧道密钥，将公钥授权给 BJ 的 tmuxrelay 用户。
3. 在 `~/.config/tmux-link/ssh_config` 中写入上方的 `Host tmux-center` 配置，IdentityFile 改为该隧道密钥的绝对路径，添加已通过可信连接核对的 BJ 主机公钥到 known_hosts，并指定 `UserKnownHostsFile` 和 `StrictHostKeyChecking yes`。
4. 将手机公钥加到 Mac 的 `~/.ssh/authorized_keys`，使用下面的受限格式。替换用户名及安装路径。主机指纹来自 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`，在手机中核对。
5. 复制 `deploy/dev.tmuxlink.tunnel.plist` 到 `~/Library/LaunchAgents/`，替换 YOUR_USER、SSH 配置路径及远端 socket。运行 `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.tmuxlink.tunnel.plist`。登录用户会话后保持隧道在线，退出登录和机器睡眠会断开。

```text
restrict,pty,command="/usr/bin/env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin /Users/YOUR_USER/.local/bin/tmux-link-agent attach" ssh-ed25519 PHONE_PUBLIC_KEY tmux-link-ios
```

手动验证出站隧道可运行下方命令。`TMUX_LINK_SSH_CONFIG` 指定独立配置文件，客户端也支持默认的 ~/.ssh/config。一个中心监听入口对应一个 socket，需要第二台机器时为它配置独立的中心实例和 HTTPS 路由。

```sh
TMUX_LINK_SSH_CONFIG="$HOME/.config/tmux-link/ssh_config" tmux-link-agent tunnel tmux-center /home/tmuxrelay/link/primary.sock 22
```

端口 443 默认使用 WSS，内网 SSH 主机指纹仍需独立核对。原有 TCP 模式可通过其他端口使用；中心启动时省略 `--websocket` 即可保持旧版传输。

## 安全与性能边界

- 主机指纹匹配且手机私钥通过 SSH 签名认证后才会启动 `agent attach`。手机私钥保存在仅本设备解锁时可读的 Keychain 项中。更换手机时重新授权公钥。删除 `phone.keys` 中对应行会拒绝后续登录，已连接的设备需要另行断开其 SSH 会话。
- 中心可以看到端点、连接时间、字节量，也可中断流量。SSH 保护会话内容。手机、Linux、tmux 插件和同用户进程仍是信任边界。进入 shell 或 AI CLI 后，操作者拥有该 主机账号自身的执行权限。
- 中心用 Tokio 双向转发，最多 32 条并发连接，未安装录屏或会话内容日志。终端按字节处理，输入和输出分别推进，输出随渲染进度施加背压。移动网络的实际延迟取决于手机、中心与 Linux 三者之间的链路。

## 验证

| 测试 | 验证内容 |
|---|---|
| 安装脚本 | 离线安装、角色选择、校验失败拒绝写入 |
| HTTPS 下载集成 | 临时 TLS 服务执行真实 `curl &#124; sh`，验证默认客户端安装、升级和损坏包拒绝 |
| tmux 集成 | 真实 Linux / OpenSSH 隧道，验证错误指纹、未授权密钥、分片输入、尺寸调整和断线重连 |
| 输入协议 | 超大帧和未知帧被拒绝并断开连接 |
| 发布包 | x86_64 和 ARM64 构建包安装后执行实际二进制 |
| iOS | 设备与 ARM64 模拟器的未签名 App 构建 |

输入缓冲区在同一连接中复用，减少连续按键和粘贴时的重复分配。SSH 即使遇到输入协议错误也会发起断开，关闭等待上限为 5 秒。

`cargo fmt --all -- --check` 和 `cargo clippy --workspace --all-targets -- -D warnings` 检查 Rust 代码。`scripts/e2e-linux.sh` 使用临时 Docker 容器和临时密钥，通过 iOS 同一 Rust FFI 入口访问真实 Linux tmux，检查错误指纹、未授权设备密钥、会话选择、输入回显、窗口尺寸和重连后的 shell 状态。Apple Silicon 上默认测试目标为 x86_64 Linux musl，Docker 需要支持运行 amd64 镜像。终端静态资源的 MIT 许可证位于 `ios/assets/`。
