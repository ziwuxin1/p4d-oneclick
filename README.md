# P4D One-Click (Ubuntu)

在一台全新的 Ubuntu VPS 上，一条命令装好 Perforce P4D，外加 systemd 自愈、每日备份和监控面板。

全程不问问题。密码自动生成，写到 `/root/p4d-oneclick-credentials.txt`（只有 root 可读）。

## 安装前准备

| 项目 | 要求 |
|---|---|
| 系统 | Ubuntu **22.04 / 24.04 LTS** |
| 架构 | **x86_64**（P4D 安装包是 x86 版本，ARM 机型跑不了） |
| 配置 | 内存 ≥ 1 GB（低于 2 GB 且没有 swap 时自动建 2 GB swap），`/opt` 可用空间 ≥ 10 GB（depot 越大，盘要越大） |
| License | **必须提供**。Perforce license 绑定服务器 IP，要用这台 VPS 的 IP 来申请或 rehost |
| 云安全组 | 放行 SSH 和 `1888/tcp`。ufw 只管机器自己的防火墙，管不到云厂商那一层 |

## 用法

```bash
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/p4d-oneclick/main/install-ubuntu.sh | sudo bash
```

就这一条命令。license 不用另外指定，脚本会自动处理：

1. 依次查找 `/root/license`、`/root/license.txt`、当前目录、之前装过的位置。空文件和文件夹会跳过。
2. 都找不到时，**直接在终端里提示你粘贴 license 内容**（用记事本打开 license，全选复制，右键粘贴，最后单独输入一行 `EOF`）。粘贴的内容会保存为 `/root/license`，重跑时不用再粘贴。

也可以显式指定 license，适合无人值守的场景：

```bash
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/p4d-oneclick/main/install-ubuntu.sh | sudo LICENSE_URL='https://example.com/license' bash
```

机器上没有 curl 时，用 git：

```bash
git clone https://github.com/ziwuxin1/p4d-oneclick.git && sudo bash p4d-oneclick/install-ubuntu.sh
```

脚本运行过程中如果发现 curl 不可用，会自动安装（`apt install curl ca-certificates`，失败时改用 `--reinstall`）。

### 选项

| 参数 / 环境变量 | 说明 |
|---|---|
| `--license PATH` / `LICENSE_FILE` | 本机上的 license 文件 |
| `--license-url URL` / `LICENSE_URL` | 从 https 地址下载 license |
| `--p4port N` / `P4PORT` | P4D 端口，默认 `1888` |
| `--no-monitor` / `INSTALL_MONITOR=0` | 不装监控面板 |
| `--monitor-public` / `MONITOR_PUBLIC=1` | 面板对公网开放。默认只监听 127.0.0.1，通过 SSH 隧道访问 |
| `--monitor-port N` / `MONITOR_PORT` | 面板端口，默认 `8080` |
| `--no-firewall` / `ENABLE_FIREWALL=0` | 不改 ufw |
| `--skip-license-ip-check` | license IP 和本机不一致时也继续装 |
| `--p4-allow-from CIDR` / `P4_ALLOW_FROM` | 只允许这个网段连 P4D，默认全网 |
| `P4D_TGZ_SHA256` | 可选，校验 P4D 安装包的 SHA256 |
| `NAS_BACKUP_ROOT` | 备份镜像目录，默认 `/var/backups/p4d-mirror`（本机目录） |
| `SMTP_USER` `SMTP_PASSWORD` `ALERT_EMAIL` | 三个都填才会启用告警邮件（Gmail App Password） |

## 它做了什么

1. **预检**：检查系统版本、架构、内存、磁盘和端口。任何一项不通过，什么都不装，直接退出。
2. **License**：检查格式，并核对 license 绑定的 IP 是否在本机网卡上。
3. **装依赖**：apt 安装所需的系统包。
4. **装 P4D**：调用 [`p4d-toolkit.sh`](p4d-toolkit.sh) 的步骤 0→4，依次是下载安装包、安装、装 license、配 systemd 自愈 hook、配 cron 备份。
5. **admin 和安全基线**：创建 `admin` 超级用户，protect 表设为只有 admin 是 super，并设置 `security=2`、`dm.user.noautocreate=2`、`run.users.authorize=1`。
6. **首次备份**：立刻做一次 checkpoint，并 rsync 到镜像目录，用来验证整条备份链路是通的。
7. **监控面板**：调用 [p4d-monitor](https://github.com/ziwuxin1/p4d-monitor) 自带的 install.sh，生成配置并启动面板。面板通过 SSH 探测本机，它的公钥只允许从 127.0.0.1 登录。
8. **防火墙**：**先放行 SSH**，再放行 P4PORT，最后启用 ufw。

脚本可以重复执行。中途失败的话，修好问题后直接重跑，已经完成的部分会自动跳过或原地覆盖。已有的 admin 密码、面板配置和 protect 表都不会被覆盖。

## 装完之后

**安装完后就可以打开控制面板**（数字菜单，终端里直接按数字选）：

```bash
sudo p4d-toolkit                              # 控制面板：体检 / 备份 / 救援 / recovery / 改密码
sudo cat /root/p4d-oneclick-credentials.txt   # 查看 P4PORT 和初始 admin 密码
```

菜单顶部会显示 `服务器: <IP>:1888`，直接复制到客户端登录。

### 更新控制面板（本仓库发新版后）

`/opt/p4d-oneclick` 是文件副本、不是 git 仓库，服务器上更新用这条（整段直接贴，30 秒完成，只刷脚本、不动 p4d / license / workshop）：

```bash
cd /tmp && sudo git clone --depth 1 https://github.com/ziwuxin1/p4d-oneclick p4d-sync && sudo cp /tmp/p4d-sync/p4d-toolkit.sh /opt/p4d-oneclick/ && sudo cp /tmp/p4d-sync/install-ubuntu.sh /opt/p4d-oneclick/ && sudo chmod +x /opt/p4d-oneclick/*.sh && rm -rf /tmp/p4d-sync && sudo p4d-toolkit
```

面板默认只在本机监听。在你自己的电脑上开一条隧道：

```bash
ssh -L 8080:127.0.0.1:8080 root@<VPS_IP>
```

然后用浏览器打开 http://localhost:8080 。

> ⚠ 默认的 `/var/backups/p4d-mirror` 在同一块盘上，**不算异地备份**。
> 挂好外置盘或 NFS 之后，修改 `/etc/ssh-toolkit.conf` 里的 `NAS_BACKUP_ROOT`。

## 已知限制

- **P4 协议是明文传输**：在公网上，密码和 ticket 都不加密。建议用 `--p4-allow-from` 限制来源 IP，或者走 Tailscale / VPN。正式使用前考虑启用 `ssl:`。
- **监控面板的 SSH key 拥有本机 root 权限**：面板需要用 root 执行探测脚本，所以面板一旦被攻破，就等于拿到了 root。默认只监听 127.0.0.1，请不要轻易加 `--monitor-public`。
- **新开的 VPS**：脚本会先等 cloud-init 跑完，再排队等 apt 锁，最多等 15 分钟。

## 文件

| 路径 | 用途 |
|---|---|
| `/opt/p4d-oneclick/p4d-toolkit.sh` | toolkit 本体，`/usr/local/sbin/p4d-toolkit` 是指向它的软链 |
| `/etc/ssh-toolkit.conf` | toolkit 配置 |
| `/etc/cron.d/p4d-backup` | 03:00 checkpoint、03:30 镜像、每周清理 |
| `/var/log/p4d-oneclick.log` | 安装日志 |
| `/opt/p4d-monitor/config/config.yaml` | 面板配置 |

## 和原版 toolkit 的区别

`p4d-toolkit.sh` 复制自 [ssh-toolkit-linux](https://github.com/ziwuxin1/ssh-toolkit-linux)。原仓库没有任何改动，这里的副本改了以下几处：

- 支持无人值守：设置 `P4D_ASSUME_YES=1` 后，所有确认都自动回答 yes；admin 密码可以通过 `P4D_ADMIN_PASSWORD` 传入。
- 可以被 `source` 当作函数库加载，加载时不会弹出菜单。
- `P4D_TGZ_URL` 可以通过环境变量覆盖。
- **修复 cron 文件**：原版用了 `\` 续行和 `[[ ]]`，cron 两样都不支持。Ubuntu 的 cron 遇到语法错误会忽略整个文件，结果连 03:00 的 checkpoint 也不会执行。现在每条任务都写成单行，rsync 改为调用 `p4d-toolkit rsync`。

## License

MIT
