# ============================================================
#  说明: SSH 服务配置脚本
#  作者: RobertHU
#  日期: 2024-12-04
#
#  用法: sudo ./configure_ssh.sh
#
#  支持的 Linux 发行版:
#    - Ubuntu 18.04 / 20.04 / 22.04 / 24.04 LTS
#    - Debian 10 (Buster) / 11 (Bullseye) / 12 (Bookworm)
#    - CentOS 7 / 8 / Stream 8 / Stream 9
#    - RHEL 7 / 8 / 9 / 10
#    - Rocky Linux 8 / 9 / 10
#    - AlmaLinux 8 / 9
#    - 其他基于 apt/dnf/yum 的发行版
#
#  功能:
#    - 检测 SSH 服务是否安装
#    - 如果未安装，自动安装 OpenSSH Server
#    - 配置是否允许 root 远程登录
#    - 配置是否允许密码登录
#    - 配置 SSH 公钥认证
# ============================================================

#!/usr/bin/env bash
# 严格模式: -e 错误退出 | -u 未定义变量报错 | -o pipefail 管道失败传递
set -euo pipefail

# ---------------------- 终端颜色定义 ----------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------- 全局变量声明 ----------------------
PKG_MGR=""                    # 包管理器类型: apt/dnf/yum
UPDATE_CMD=""                 # 更新缓存命令
INSTALL_CMD=""                # 安装包命令
SERVICE_CMD=""                # 服务管理命令: systemctl/service

SSH_CONFIG_FILE="/etc/ssh/sshd_config"  # SSH 配置文件路径
SSH_CONFIG_BACKUP=""          # 配置文件备份路径
SSH_PACKAGE_NAME=""           # SSH 服务包名
ALLOW_ROOT_LOGIN=""           # 是否允许 root 登录: yes/no
ALLOW_PASSWORD_AUTH=""        # 是否允许密码认证: yes/no
SSH_PUBLIC_KEY=""             # SSH 公钥内容
SSH_USER=""                   # 配置公钥的用户（默认 root）

# ---------------------- 输出辅助函数 ----------------------

print_section() {
  local title="$1"
  echo
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $title${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo
}

print_subsection() {
  local title="$1"
  echo
  echo -e "${YELLOW}───────────────────────────────────────${NC}"
  echo -e "${YELLOW}  $title${NC}"
  echo -e "${YELLOW}───────────────────────────────────────${NC}"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
  echo -e "${BLUE}ℹ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}" >&2
}

# ---------------------- 权限检查 ----------------------

if [[ $EUID -ne 0 ]]; then
  print_error "请使用 root 运行[例如 sudo $0]"
  exit 1
fi

print_section "SSH 服务配置脚本"

# ---------------------- 包管理器检测 ----------------------

if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
  UPDATE_CMD="apt-get update -y"
  INSTALL_CMD="apt-get install -y"
  SSH_PACKAGE_NAME="openssh-server"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
  UPDATE_CMD="dnf makecache -y"
  INSTALL_CMD="dnf install -y"
  SSH_PACKAGE_NAME="openssh-server"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
  UPDATE_CMD="yum makecache -y"
  INSTALL_CMD="yum install -y"
  SSH_PACKAGE_NAME="openssh-server"
else
  print_error "未检测到受支持的包管理器[apt/dnf/yum]，无法继续。"
  exit 1
fi

print_success "检测到包管理器: $PKG_MGR"

# ---------------------- 服务管理命令检测 ----------------------

if command -v systemctl >/dev/null 2>&1; then
  SERVICE_CMD="systemctl"
elif command -v service >/dev/null 2>&1; then
  SERVICE_CMD="service"
else
  print_error "未检测到服务管理命令[systemctl/service]，无法继续。"
  exit 1
fi

print_success "检测到服务管理命令: $SERVICE_CMD"

# ---------------------- 检测 SSH 服务是否安装 ----------------------

print_section "1/4 检测 SSH 服务状态"

SSH_INSTALLED=false
SSH_RUNNING=false

# 检查 SSH 服务是否安装
if command -v sshd >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q "sshd.service\|ssh.service" || service sshd status >/dev/null 2>&1 || service ssh status >/dev/null 2>&1; then
  SSH_INSTALLED=true
  print_success "SSH 服务已安装"
  
  # 检查 SSH 服务是否运行
  if [[ "$SERVICE_CMD" == "systemctl" ]]; then
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
      SSH_RUNNING=true
      print_success "SSH 服务正在运行"
    else
      print_warning "SSH 服务已安装但未运行"
    fi
  elif [[ "$SERVICE_CMD" == "service" ]]; then
    if service sshd status >/dev/null 2>&1 || service ssh status >/dev/null 2>&1; then
      SSH_RUNNING=true
      print_success "SSH 服务正在运行"
    else
      print_warning "SSH 服务已安装但未运行"
    fi
  fi
else
  print_warning "SSH 服务未安装"
fi

# ---------------------- 安装 SSH 服务（如果未安装） ----------------------

if [[ "$SSH_INSTALLED" == false ]]; then
  print_subsection "安装 SSH 服务"
  
  print_info "正在更新软件包缓存..."
  bash -c "$UPDATE_CMD" >/dev/null 2>&1 || true
  
  print_info "正在安装 $SSH_PACKAGE_NAME..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
  fi
  
  if bash -c "$INSTALL_CMD $SSH_PACKAGE_NAME"; then
    print_success "SSH 服务安装完成"
    SSH_INSTALLED=true
  else
    print_error "SSH 服务安装失败，请检查网络连接和软件源配置"
    exit 1
  fi
  
  # 启动 SSH 服务
  print_info "正在启动 SSH 服务..."
  if [[ "$SERVICE_CMD" == "systemctl" ]]; then
    systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
    systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
  elif [[ "$SERVICE_CMD" == "service" ]]; then
    chkconfig sshd on 2>/dev/null || true
    service sshd start 2>/dev/null || service ssh start 2>/dev/null || true
  fi
  
  if [[ "$SERVICE_CMD" == "systemctl" ]]; then
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
      SSH_RUNNING=true
      print_success "SSH 服务已启动"
    else
      print_warning "SSH 服务启动失败，请手动检查"
    fi
  else
    SSH_RUNNING=true
    print_success "SSH 服务已启动"
  fi
fi

# ---------------------- 备份配置文件 ----------------------

print_section "2/4 配置 SSH 服务"

print_subsection "备份配置文件"

if [[ ! -f "$SSH_CONFIG_FILE" ]]; then
  print_error "SSH 配置文件不存在: $SSH_CONFIG_FILE"
  exit 1
fi

SSH_CONFIG_BACKUP="${SSH_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$SSH_CONFIG_FILE" "$SSH_CONFIG_BACKUP"
print_success "配置文件已备份到: $SSH_CONFIG_BACKUP"

# ---------------------- 配置 Root 登录 ----------------------

print_subsection "配置 Root 远程登录"

# 读取当前配置
CURRENT_ROOT_LOGIN=$(grep -E "^PermitRootLogin|^#PermitRootLogin" "$SSH_CONFIG_FILE" | tail -1 | awk '{print $2}' || echo "prohibit-password")

print_info "当前 PermitRootLogin 配置: ${CURRENT_ROOT_LOGIN:-未设置（默认: prohibit-password）}"

while true; do
  read -rp "是否允许 root 用户远程登录? [y/N]: " root_input
  root_input="${root_input:-N}"
  case "${root_input,,}" in
    y|yes)
      ALLOW_ROOT_LOGIN="yes"
      break
      ;;
    n|no|"")
      ALLOW_ROOT_LOGIN="no"
      break
      ;;
    *)
      print_warning "请输入 y 或 n"
      ;;
  esac
done

# 修改配置文件
if [[ "$ALLOW_ROOT_LOGIN" == "yes" ]]; then
  # 注释掉或替换现有的 PermitRootLogin 配置
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSH_CONFIG_FILE"
  # 如果文件中没有 PermitRootLogin，添加它
  if ! grep -q "^PermitRootLogin" "$SSH_CONFIG_FILE"; then
    echo "PermitRootLogin yes" >> "$SSH_CONFIG_FILE"
  fi
  print_success "已配置允许 root 远程登录"
else
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG_FILE"
  if ! grep -q "^PermitRootLogin" "$SSH_CONFIG_FILE"; then
    echo "PermitRootLogin no" >> "$SSH_CONFIG_FILE"
  fi
  print_success "已配置禁止 root 远程登录"
fi

# ---------------------- 配置密码认证 ----------------------

print_subsection "配置密码认证"

# 读取当前配置
CURRENT_PASSWORD_AUTH=$(grep -E "^PasswordAuthentication|^#PasswordAuthentication" "$SSH_CONFIG_FILE" | tail -1 | awk '{print $2}' || echo "yes")

print_info "当前 PasswordAuthentication 配置: ${CURRENT_PASSWORD_AUTH:-未设置（默认: yes）}"

while true; do
  read -rp "是否允许密码登录? [Y/n]: " password_input
  password_input="${password_input:-Y}"
  case "${password_input,,}" in
    y|yes|"")
      ALLOW_PASSWORD_AUTH="yes"
      break
      ;;
    n|no)
      ALLOW_PASSWORD_AUTH="no"
      break
      ;;
    *)
      print_warning "请输入 y 或 n"
      ;;
  esac
done

# 修改配置文件
if [[ "$ALLOW_PASSWORD_AUTH" == "yes" ]]; then
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG_FILE"
  if ! grep -q "^PasswordAuthentication" "$SSH_CONFIG_FILE"; then
    echo "PasswordAuthentication yes" >> "$SSH_CONFIG_FILE"
  fi
  print_success "已配置允许密码登录"
else
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG_FILE"
  if ! grep -q "^PasswordAuthentication" "$SSH_CONFIG_FILE"; then
    echo "PasswordAuthentication no" >> "$SSH_CONFIG_FILE"
  fi
  print_success "已配置禁止密码登录"
  
  # 如果不允许密码登录，必须配置公钥认证
  print_warning "已禁用密码登录，必须配置 SSH 公钥认证才能登录"
fi

# ---------------------- 配置公钥认证 ----------------------

print_subsection "配置 SSH 公钥认证"

# 确保启用公钥认证
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG_FILE"
if ! grep -q "^PubkeyAuthentication" "$SSH_CONFIG_FILE"; then
  echo "PubkeyAuthentication yes" >> "$SSH_CONFIG_FILE"
fi

# 如果禁用了密码登录，必须配置公钥
if [[ "$ALLOW_PASSWORD_AUTH" == "no" ]]; then
  print_info "由于已禁用密码登录，必须配置 SSH 公钥才能登录"
  
  while true; do
    echo
    print_info "请输入 SSH 公钥（单行，粘贴完整公钥后按 Enter）:"
    print_info "公钥格式示例: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... user@host"
    print_info "或者输入公钥文件路径（如 /path/to/id_rsa.pub）:"
    echo
    
    read -rp "公钥内容或文件路径: " key_input
    
    if [[ -z "$key_input" ]]; then
      print_warning "公钥不能为空，请重新输入"
      continue
    fi
    
    # 检查是否是文件路径
    if [[ -f "$key_input" ]]; then
      SSH_PUBLIC_KEY=$(cat "$key_input" | head -1)
      print_info "已从文件读取公钥: $key_input"
    else
      SSH_PUBLIC_KEY="$key_input"
    fi
    
    # 去除首尾空白
    SSH_PUBLIC_KEY=$(echo "$SSH_PUBLIC_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [[ -z "$SSH_PUBLIC_KEY" ]]; then
      print_warning "公钥内容为空，请重新输入"
      continue
    fi
    
    # 验证公钥格式（简单检查）
    if echo "$SSH_PUBLIC_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|ssh-dss) "; then
      break
    else
      print_warning "公钥格式可能不正确，请确认后重新输入"
      read -rp "是否继续? [y/N]: " continue_input
      if [[ "${continue_input,,}" != "y" ]] && [[ "${continue_input,,}" != "yes" ]]; then
        continue
      else
        break
      fi
    fi
  done
  
  # 询问要配置公钥的用户
  read -rp "请输入要配置公钥的用户名[默认: root]: " user_input
  SSH_USER="${user_input:-root}"
  
  # 创建 .ssh 目录
  USER_HOME=$(eval echo ~"$SSH_USER")
  SSH_DIR="${USER_HOME}/.ssh"
  AUTHORIZED_KEYS_FILE="${SSH_DIR}/authorized_keys"
  
  print_info "正在为用户 $SSH_USER 配置公钥..."
  
  # 创建 .ssh 目录
  if [[ ! -d "$SSH_DIR" ]]; then
    mkdir -p "$SSH_DIR"
    print_success "已创建目录: $SSH_DIR"
  fi
  
  # 设置正确的权限
  chmod 700 "$SSH_DIR"
  print_success "已设置目录权限: 700"
  
  # 添加公钥到 authorized_keys
  if [[ -f "$AUTHORIZED_KEYS_FILE" ]]; then
    # 检查公钥是否已存在
    if grep -Fxq "$SSH_PUBLIC_KEY" "$AUTHORIZED_KEYS_FILE" 2>/dev/null; then
      print_warning "该公钥已存在于 authorized_keys 文件中"
    else
      echo "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS_FILE"
      print_success "公钥已添加到: $AUTHORIZED_KEYS_FILE"
    fi
  else
    echo "$SSH_PUBLIC_KEY" > "$AUTHORIZED_KEYS_FILE"
    print_success "已创建并添加公钥到: $AUTHORIZED_KEYS_FILE"
  fi
  
  # 设置正确的文件权限
  chmod 600 "$AUTHORIZED_KEYS_FILE"
  print_success "已设置文件权限: 600"
  
  # 设置所有者
  chown -R "$SSH_USER:$SSH_USER" "$SSH_DIR"
  print_success "已设置所有者: $SSH_USER"
  
  print_success "SSH 公钥配置完成"
else
  # 即使允许密码登录，也可以选择配置公钥
  echo
  while true; do
    read -rp "是否要配置 SSH 公钥认证? [y/N]: " pubkey_input
    pubkey_input="${pubkey_input:-N}"
    case "${pubkey_input,,}" in
      y|yes)
        echo
        print_info "请输入 SSH 公钥（单行，粘贴完整公钥后按 Enter）:"
        print_info "公钥格式示例: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... user@host"
        print_info "或者输入公钥文件路径（如 /path/to/id_rsa.pub）:"
        echo
        
        read -rp "公钥内容或文件路径: " key_input
        
        if [[ -n "$key_input" ]]; then
          # 检查是否是文件路径
          if [[ -f "$key_input" ]]; then
            SSH_PUBLIC_KEY=$(cat "$key_input" | head -1)
            print_info "已从文件读取公钥: $key_input"
          else
            SSH_PUBLIC_KEY="$key_input"
          fi
          
          # 去除首尾空白
          SSH_PUBLIC_KEY=$(echo "$SSH_PUBLIC_KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
        
        if [[ -n "$SSH_PUBLIC_KEY" ]]; then
          read -rp "请输入要配置公钥的用户名[默认: root]: " user_input
          SSH_USER="${user_input:-root}"
          
          USER_HOME=$(eval echo ~"$SSH_USER")
          SSH_DIR="${USER_HOME}/.ssh"
          AUTHORIZED_KEYS_FILE="${SSH_DIR}/authorized_keys"
          
          print_info "正在为用户 $SSH_USER 配置公钥..."
          
          if [[ ! -d "$SSH_DIR" ]]; then
            mkdir -p "$SSH_DIR"
            print_success "已创建目录: $SSH_DIR"
          fi
          
          chmod 700 "$SSH_DIR"
          
          if [[ -f "$AUTHORIZED_KEYS_FILE" ]]; then
            if grep -Fxq "$SSH_PUBLIC_KEY" "$AUTHORIZED_KEYS_FILE" 2>/dev/null; then
              print_warning "该公钥已存在于 authorized_keys 文件中"
            else
              echo "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS_FILE"
              print_success "公钥已添加到: $AUTHORIZED_KEYS_FILE"
            fi
          else
            echo "$SSH_PUBLIC_KEY" > "$AUTHORIZED_KEYS_FILE"
            print_success "已创建并添加公钥到: $AUTHORIZED_KEYS_FILE"
          fi
          
          chmod 600 "$AUTHORIZED_KEYS_FILE"
          chown -R "$SSH_USER:$SSH_USER" "$SSH_DIR"
          print_success "SSH 公钥配置完成"
        fi
        break
        ;;
      n|no|"")
        print_info "跳过公钥配置"
        break
        ;;
      *)
        print_warning "请输入 y 或 n"
        ;;
    esac
  done
fi

# ---------------------- 验证配置文件 ----------------------

print_section "3/4 验证配置"

print_subsection "检查配置文件语法"

if sshd -t -f "$SSH_CONFIG_FILE" 2>/dev/null; then
  print_success "SSH 配置文件语法检查通过"
else
  print_error "SSH 配置文件语法检查失败"
  print_warning "正在恢复备份配置文件..."
  cp "$SSH_CONFIG_BACKUP" "$SSH_CONFIG_FILE"
  print_error "已恢复备份，请检查配置后重试"
  exit 1
fi

# ---------------------- 重启 SSH 服务 ----------------------

print_section "4/4 应用配置"

print_subsection "重启 SSH 服务"

print_warning "即将重启 SSH 服务，请确保有其他方式访问服务器（如控制台）"
print_info "等待 5 秒，按 Ctrl+C 取消..."

for i in {5..1}; do
  echo -ne "\r${i} 秒后重启 SSH 服务... "
  sleep 1
done
echo

print_info "正在重启 SSH 服务..."

if [[ "$SERVICE_CMD" == "systemctl" ]]; then
  if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
    print_success "SSH 服务已重启"
  else
    print_error "SSH 服务重启失败"
    exit 1
  fi
elif [[ "$SERVICE_CMD" == "service" ]]; then
  if service sshd restart 2>/dev/null || service ssh restart 2>/dev/null; then
    print_success "SSH 服务已重启"
  else
    print_error "SSH 服务重启失败"
    exit 1
  fi
fi

# 检查服务状态
sleep 2
if [[ "$SERVICE_CMD" == "systemctl" ]]; then
  if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
    print_success "SSH 服务运行正常"
  else
    print_error "SSH 服务未运行，请检查配置"
    exit 1
  fi
fi

# ---------------------- 显示配置摘要 ----------------------

echo
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│                    配置完成                                 │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "配置文件" "$SSH_CONFIG_FILE"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "备份文件" "$SSH_CONFIG_BACKUP"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "Root 登录" "$ALLOW_ROOT_LOGIN"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "密码认证" "$ALLOW_PASSWORD_AUTH"
if [[ -n "$SSH_USER" ]] && [[ -n "$SSH_PUBLIC_KEY" ]]; then
  printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "公钥用户" "$SSH_USER"
  printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "公钥文件" "$(eval echo ~"$SSH_USER")/.ssh/authorized_keys"
fi
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│${NC}  测试 SSH 连接: ${GREEN}ssh user@hostname${NC}                          ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  查看 SSH 状态: ${GREEN}systemctl status sshd${NC}                      ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  查看 SSH 日志: ${GREEN}journalctl -u sshd -f${NC}                        ${CYAN}│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo

print_success "SSH 配置完成！"

