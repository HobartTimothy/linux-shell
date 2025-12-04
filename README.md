## linux-shell

Linux 服务器常用运维脚本集合，方便一键安装组件和进行基础优化。

---

## 目录结构

- `linux/`：Linux 系统通用优化脚本（内核参数 + 磁盘清理）。
- `nginx/`：Nginx 安装脚本。
- `mysql/`：MySQL 安装与主从复制配置脚本。
- `ssh/`：SSH 基础安全配置脚本。

---

## 使用前准备

- 建议使用 **root** 或具备 `sudo` 权限的用户执行。
- 执行前给脚本添加执行权限（只需给你要用的脚本加即可）：

```bash
chmod +x linux/*.sh
chmod +x nginx/*.sh
chmod +x mysql/*.sh
chmod +x ssh/*.sh
```

所有脚本均为 **bash**，在大部分常见发行版上可直接执行。

---

## Linux 系统优化脚本（`linux/`）

### 说明

`linux/` 目录下包含一组针对不同发行版的入口脚本，最终逻辑统一在 `optimize_common.sh` 中实现：

- `optimize_ubuntu.sh`
- `optimize_debian.sh`
- `optimize_centos.sh`
- `optimize_rhel.sh`
- `optimize_rocky.sh`
- `optimize_alma.sh`
- `optimize_fedora.sh`
- `optimize_opensuse.sh`
- `optimize_arch.sh`
- `optimize_common.sh`：真正执行优化逻辑（根据 `/etc/os-release` 自动识别发行版）。

主要功能：

- **内核参数调优**（`sysctl`）：
  - 网络连接队列、端口范围、TCP 缓冲区等常用服务型参数。
  - 文件句柄数、内核队列等资源限制。
  - 虚拟内存策略（`vm.swappiness`、`vm.overcommit_memory` 等）。
- **磁盘清理**：
  - 针对 APT、YUM/DNF、Pacman 等包管理器的缓存清理。
  - `journalctl` 日志按时间裁剪。
  - 清理 `/tmp` 中长时间未使用文件。

### 使用示例

根据实际系统选择对应脚本执行即可（脚本会自动用 `sudo` 重新运行）：

```bash
# Ubuntu / Debian
./linux/optimize_ubuntu.sh
# or
./linux/optimize_debian.sh

# CentOS / RHEL / Rocky / Alma / Fedora
./linux/optimize_centos.sh
./linux/optimize_rhel.sh
./linux/optimize_rocky.sh
./linux/optimize_alma.sh
./linux/optimize_fedora.sh

# openSUSE
./linux/optimize_opensuse.sh

# Arch / Manjaro
./linux/optimize_arch.sh
```

> **建议**：先在测试环境执行并验证业务指标，再应用到生产环境。

---

## Nginx 安装脚本（`nginx/`）

- `install_nginx.sh`：一键安装并基础配置 Nginx（具体逻辑以脚本内容为准）。

### 使用示例

```bash
./nginx/install_nginx.sh
```

根据提示完成安装即可，若有需要可自行扩展为自动生成站点配置等。

---

## MySQL 脚本（`mysql/`）

- `install_mysql.sh`：安装并进行基础配置 MySQL。
- `setup_mysql_replication.sh`：配置 MySQL 主从复制（master/slave 或 primary/replica）。

### 使用示例

```bash
# 安装 MySQL
./mysql/install_mysql.sh

# 配置主从复制（在主库和从库按脚本内提示分别执行）
./mysql/setup_mysql_replication.sh
```

请根据脚本中的变量（例如 root 密码、复制账号、主从 IP 等）进行适配后再执行。

---

## SSH 配置脚本（`ssh/`）

- `configure_ssh.sh`：对 `sshd_config` 做一些基础安全配置（如端口、密码登录、密钥登录等，具体以脚本内容为准）。

### 使用示例

```bash
./ssh/configure_ssh.sh
```

**提示**：修改 SSH 配置后不要立刻退出当前会话，建议新开一个终端窗口验证可以正常登录，再关闭旧会话，避免配置错误导致远程锁死。

---

## 注意事项 & 建议

- 所有脚本均假设在标准 Linux 发行版上运行，部分命令可能因系统差异需要微调。
- 在 **生产环境执行前**，请务必先在 **测试环境** 上验证：
  - 安装/配置是否符合预期。
  - 内核参数及资源限制是否对业务有正向帮助。
- 可以将这些脚本作为基础模板，根据自己公司的规范和业务特性做二次封装。

