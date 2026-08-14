# CLIProxyAPI 一键安装与卸载

> [English](README.md) | 简体中文

> **读者**：负责部署和维护 CLIProxyAPI 的开发或运维人员。**前置**：拥有目标 Ubuntu 主机的 root 权限和公网 IPv4。**读完能**：完成 HTTPS 安装、远程管理配置、日常检查和安全卸载。

本仓库提供两个脚本，用于在 Ubuntu systemd 主机上安装或卸载 [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)：

- `install-cliproxyapi.sh`：安装官方发布包、校验 SHA256、申请 Let's Encrypt IP 证书、配置 systemd 开机自启和证书自动续期。
- `uninstall-cliproxyapi.sh`：支持预演、保留数据卸载和完整清理。

> 文中的 `203.0.113.10` 是文档示例地址，执行前必须替换为目标主机真实的公网 IPv4。

## 重要端口说明

CLIProxyAPI 的 API 与管理页面共用同一个 HTTPS 监听端口。`--management-port` 设置的是这个共享端口，不是独立的管理端口。

- 默认端口：`443`
- API 示例：`https://203.0.113.10/v1/models`
- 管理页面：`https://203.0.113.10/management.html`
- 证书申请和续期：公网 `80/tcp`，该端口不能用作 API 与管理页面的共享端口

脚本不会配置主机防火墙、云防火墙或安全组。证书申请和续期要求目标 IPv4 的公网 `80/tcp` 可达，并且本机端口 80 没有其他监听进程。

## 环境要求

- Ubuntu，使用 systemd 和 `apt-get`
- root 权限
- `x86_64`、`aarch64` 或 `arm64`
- 公网 IPv4 已绑定到目标主机的全局网络接口
- 安装端口未被其他进程占用
- 公网 `80/tcp` 可达，用于 Certbot standalone HTTP-01 challenge
- 能访问 GitHub、Ubuntu 软件源、Snap Store 和 Let's Encrypt

安装脚本会安装或使用以下系统依赖：`ca-certificates`、`curl`、`iproute2`、`openssl`、`python3`、`snapd`、`tar`、`util-linux` 和 Certbot snap。

## 快速安装

在保存脚本的本机执行：

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --management-port 443 --enable-remote-management' \
  < ./install-cliproxyapi.sh
```

该命令会：

1. 下载默认固定版本 `v7.2.131`，并用官方 `checksums.txt` 校验发布包。
2. 创建受限系统用户 `cliproxy`。
3. 申请包含目标 IPv4 SAN 的短期 Let's Encrypt 证书。
4. 在目标 IPv4 的 443 端口启动 API 和远程管理页面。
5. 启用 `cli-proxy-api.service` 和 Certbot 续期 timer。
6. 验证 API 鉴权、管理鉴权和证书续期 dry-run。

安装成功后访问：

```text
https://203.0.113.10/management.html
```

### 获取管理密码

管理密码只保存在 root 可读的环境文件中，安装脚本不会打印密码：

```bash
ssh root@203.0.113.10 \
  "sed -n 's/^MANAGEMENT_PASSWORD=//p' /etc/cli-proxy-api/management.env"
```

把输出视为 secret，不要写入脚本、日志、聊天记录或版本控制。

### 获取客户端 API key

客户端 API key 位于 `/var/lib/cli-proxy-api/config.yaml` 的 `api-keys` 段。读取该文件时按敏感配置处理，不要复制整个配置到日志或文档。

只读取安装器生成的第一个 API key：

```bash
ssh root@203.0.113.10 \
  "sed -n '/^api-keys:/{n;s/^[[:space:]]*-[[:space:]]*//;s/^\"//;s/\"$//;p;q;}' /var/lib/cli-proxy-api/config.yaml"
```

API 调用示例：

```bash
curl --fail \
  -H 'Authorization: Bearer <api-key>' \
  https://203.0.113.10/v1/models
```

## 安装选项

| 选项 | 默认值 | 说明 |
|---|---:|---|
| `--ip <public-ipv4>` | 必填 | 证书身份及服务绑定的公网 IPv4 |
| `--management-port <port>` | `443` | API 与管理页面共用的 HTTPS 端口，可选 `1..65535`，但不能使用 Certbot 保留的 `80` |
| `--enable-remote-management` | 新装时关闭 | 开启管理页面和远程管理 API |
| `--disable-remote-management` | — | 关闭管理页面和远程管理 API |
| `--cliproxy-version <tag\|latest>` | `v7.2.131` | 安装固定 release tag，或解析 GitHub 最新 release |
| `--acme-email <email>` | 无 | 为 Let's Encrypt 账户登记邮箱 |
| `-h`, `--help` | — | 显示帮助 |

脚本也读取 `CLIPROXY_VERSION` 和 `ACME_EMAIL` 环境变量。最终取值优先级为：命令行选项 > 环境变量 > 表中的内置默认值；`ACME_EMAIL` 没有内置默认值。

开启其他共享端口，例如 8443：

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --management-port 8443 --enable-remote-management' \
  < ./install-cliproxyapi.sh
```

关闭远程管理但保留 API：

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --management-port 443 --disable-remote-management' \
  < ./install-cliproxyapi.sh
```

### 重复执行和升级

安装脚本可以重复执行：

- 已有受管配置会保留 API key 和其他未由安装器管理的设置。
- 未传管理开关时，新装默认关闭管理面；已有受管安装保留当前的全开或全关状态。
- 如果 `allow-remote` 与 `disable-control-panel` 是混合状态，脚本会停止并要求显式传入启用或禁用开关。
- 使用 `--cliproxy-version <tag>` 安装指定版本；使用 `latest` 时会在执行时解析 GitHub 最新 release。

## 日常运维

查看服务状态：

```bash
ssh root@203.0.113.10 'systemctl status cli-proxy-api.service --no-pager'
```

查看日志：

```bash
ssh root@203.0.113.10 'journalctl -u cli-proxy-api.service -n 100 --no-pager'
```

查看监听端口：

```bash
management_port=443
ssh root@203.0.113.10 "ss -lnt 'sport = :${management_port}'"
```

如果安装时选择了其他端口，把 `management_port` 改为实际端口。

检查证书 SAN 和有效期：

```bash
ssh root@203.0.113.10 \
  "openssl x509 -in /etc/cli-proxy-api/tls/fullchain.pem -noout -dates -ext subjectAltName"
```

检查续期 timer：

```bash
ssh root@203.0.113.10 \
  'systemctl status snap.certbot.renew.timer --no-pager'
```

## 文件与权限

| 路径 | 用途 |
|---|---|
| `/usr/local/bin/cli-proxy-api` | CLIProxyAPI 二进制 |
| `/etc/systemd/system/cli-proxy-api.service` | systemd 服务单元 |
| `/var/lib/cli-proxy-api/config.yaml` | 受管配置和客户端 API key，`cliproxy:cliproxy`、`0600` |
| `/etc/cli-proxy-api/management.env` | 管理密码，`root:root`、`0600`；管理关闭时不存在 |
| `/etc/cli-proxy-api/tls/` | 服务使用的证书副本 |
| `/var/lib/cli-proxy-api/auth/` | CLIProxyAPI 认证状态目录 |
| `/var/lib/cli-proxy-api/static/` | 管理页面静态资源目录 |
| `/etc/letsencrypt/renewal-hooks/deploy/50-cliproxyapi` | 续期后复制证书并重启服务的 hook |

服务以非 root 用户 `cliproxy` 运行。监听 443 等低端口时，systemd 只授予 `CAP_NET_BIND_SERVICE`。

## 卸载

### 先预演

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --purge --dry-run' \
  < ./uninstall-cliproxyapi.sh
```

`--dry-run` 只列出精确目标，不修改主机。

### 卸载程序，保留数据

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --yes' \
  < ./uninstall-cliproxyapi.sh
```

该模式删除 systemd 服务、二进制和续期 deploy hook，但保留配置、凭据、状态、证书和 `cliproxy` 用户，便于之后重新安装。

### 完整清理

> **警告**：`--purge` 会删除配置、客户端 API key、管理密码、认证状态、IP 证书以及 `cliproxy` 用户和组。确认不再需要这些数据后再执行。

```bash
ssh root@203.0.113.10 \
  'bash -s -- --ip 203.0.113.10 --purge --yes' \
  < ./uninstall-cliproxyapi.sh
```

卸载脚本不会删除共享的 Certbot 或 snapd 软件包。

## 常见问题

### 端口已被占用

安装器会拒绝覆盖其他进程使用的目标端口。先用 `ss -lntp` 找到占用者，再决定调整该服务或改用 `--management-port`。

### 证书申请或续期失败

确认以下条件：

- `--ip` 与主机全局网络接口上的公网 IPv4 完全一致。
- 本机 80 端口没有监听进程。
- 云防火墙、安全组、上游 NAT 和主机防火墙允许公网访问 `80/tcp`。
- DNS 域名不是必需项；本脚本申请的是 IP SAN 证书。

查看 Certbot 日志：

```bash
ssh root@203.0.113.10 'journalctl -u snap.certbot.renew.service --no-pager'
```

### 管理页面不可访问

确认安装时传入了 `--enable-remote-management`，并检查服务状态、共享 HTTPS 端口和网络访问策略。管理页面可加载不代表管理 API 已通过鉴权；登录仍需要 `/etc/cli-proxy-api/management.env` 中的密码。

## 安全边界

- 开启远程管理后，管理入口会暴露在目标 HTTPS 端口上，并由管理密码保护。
- API key、管理密码、TLS 私钥和认证目录都应视为 secret 或敏感数据。
- 脚本不会把生成的 API key 或管理密码打印到安装输出。
- 脚本不会配置访问源限制、速率限制、反向代理或云防火墙。
- 不要把真实凭据、配置文件或证书提交到版本控制。
