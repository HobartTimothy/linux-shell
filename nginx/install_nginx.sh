# ============================================================
#  说明: Nginx 源码编译安装脚本
#  作者: RobertHU
#  日期: 2024-12-04
#
#  用法: sudo ./install_nginx.sh
#        或设置环境变量: NGINX_PREFIX="/usr/local/nginx" NGINX_CONF_PATH="/etc/nginx/nginx.conf" ENABLE_MAIL_MODULES="yes" sudo ./install_nginx.sh
#
#  支持的 Linux 发行版:
#    - Ubuntu 18.04 / 20.04 / 22.04 / 24.04 LTS
#    - Debian 10 (Buster) / 11 (Bullseye) / 12 (Bookworm)
#    - CentOS 7 / 8 / Stream 8 / Stream 9
#    - RHEL 7 / 8 / 9 / 10
#    - Rocky Linux 8 / 9 / 10
#    - AlmaLinux 8 / 9
#
#  功能:
#    - 检测系统是否支持编译最新版本 Nginx
#    - 自动获取最新稳定版本
#    - 下载源码并编译安装
#    - 支持自定义安装路径和配置文件路径
#    - 支持选择是否安装邮件模块（IMAP/POP3/SMTP）
#    - 支持自定义配置 Stream (TCP/UDP) 模块
#    - 支持自定义配置 HTTP 模块（60+ 个模块可选）
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

NGINX_VERSION=""              # Nginx 版本号
NGINX_PREFIX=""               # 安装路径前缀
NGINX_CONF_PATH=""            # 配置文件路径
NGINX_PID_PATH=""             # PID 文件路径
NGINX_LOG_PATH=""             # 日志文件路径
ENABLE_MAIL_MODULES=""        # 是否启用邮件模块: yes/no

# Stream 模块配置（关联数组）
declare -A STREAM_MODULES     # 存储用户选择的 stream 模块

# HTTP 模块配置（关联数组）
declare -A HTTP_MODULES        # 存储用户选择的 http 模块
declare -A CORE_HTTP_MODULES_MAP  # 核心 HTTP 模块快速查找表

BUILD_DIR="/tmp/nginx_build"  # 临时编译目录
CPU_CORES=0                   # CPU 核数

# 默认值常量
readonly DEFAULT_PREFIX="/usr/local/nginx"
readonly DEFAULT_CONF_PATH="/etc/nginx/nginx.conf"
readonly DEFAULT_PID_PATH="/var/run/nginx.pid"
readonly DEFAULT_LOG_PATH="/var/log/nginx"

# 必需的编译依赖
readonly REQUIRED_BUILD_DEPS_APT="build-essential libpcre3-dev zlib1g-dev libssl-dev wget curl"
readonly REQUIRED_BUILD_DEPS_YUM="gcc pcre-devel zlib-devel openssl-devel wget curl make"

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

# ---------------------- 清理函数 ----------------------

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    print_error "脚本执行失败，退出码: $exit_code"
    if [[ -d "${BUILD_DIR:-}" ]]; then
      print_info "清理临时文件..."
      rm -rf "$BUILD_DIR"
    fi
  fi
  exit $exit_code
}

# 注册清理函数，在脚本异常退出时执行
trap cleanup ERR INT TERM

# ---------------------- 模块解析辅助函数 ----------------------

# 解析模块信息字符串，返回指定字段
# 用法: get_module_field "stream_ssl|--with-stream_ssl_module|分类|描述" 1
# 参数: $1=模块信息字符串, $2=字段索引(1=名称, 2=编译选项, 3=分类, 4=描述)
get_module_field() {
  local module_info="$1"
  local field_index="$2"
  echo "$module_info" | cut -d'|' -f"$field_index"
}

# 获取模块名称
get_module_name() {
  get_module_field "$1" 1
}

# 获取编译选项
get_module_compile_opt() {
  get_module_field "$1" 2
}

# 获取模块分类
get_module_category() {
  get_module_field "$1" 3
}

# 获取模块描述
get_module_description() {
  get_module_field "$1" 4
}

# 初始化模块状态（通用函数）
init_modules() {
  local -n module_list="$1"
  local -n module_state="$2"
  local module_info
  for module_info in "${module_list[@]}"; do
    local module_name
    module_name=$(get_module_name "$module_info")
    module_state["$module_name"]="no"
  done
}

# 设置默认启用的模块（通用函数）
set_default_modules() {
  local -n default_modules="$1"
  local -n module_state="$2"
  local module
  for module in "${default_modules[@]}"; do
    module_state["$module"]="yes"
  done
}

# 启用所有模块（通用函数）
enable_all_modules() {
  local -n module_list="$1"
  local -n module_state="$2"
  local module_info
  for module_info in "${module_list[@]}"; do
    local module_name
    module_name=$(get_module_name "$module_info")
    module_state["$module_name"]="yes"
  done
}

# 初始化 Stream 模块状态
init_stream_modules() {
  init_modules STREAM_MODULE_LIST STREAM_MODULES
}

# 设置默认启用的 Stream 模块
set_default_stream_modules() {
  set_default_modules DEFAULT_STREAM_MODULES STREAM_MODULES
}

# 重置所有 Stream 模块为未启用
reset_all_stream_modules() {
  init_stream_modules
}

# 启用所有 Stream 模块
enable_all_stream_modules() {
  enable_all_modules STREAM_MODULE_LIST STREAM_MODULES
}

# 显示模块列表（通用函数）
display_modules() {
  local -n module_list="$1"
  local -n module_state="$2"
  local -n core_modules="${3:-}"
  local current_category=""
  local module_index=1
  local module_info
  
  for module_info in "${module_list[@]}"; do
    local module_name compile_opt category description current_status status_mark is_core
    module_name=$(get_module_name "$module_info")
    compile_opt=$(get_module_compile_opt "$module_info")
    category=$(get_module_category "$module_info")
    description=$(get_module_description "$module_info")
    current_status="${module_state[$module_name]:-no}"
    
    # 检查是否是核心模块（如果提供了核心模块列表）
    is_core="no"
    if [[ -n "${core_modules:-}" ]]; then
      if [[ -n "${core_modules[$module_name]:-}" ]]; then
        is_core="yes"
        # 核心模块强制启用
        module_state["$module_name"]="yes"
        current_status="yes"
      fi
    fi
    
    # 显示分类标题
    if [[ "$current_category" != "$category" ]]; then
      if [[ -n "$current_category" ]]; then
        echo
      fi
      echo -e "${YELLOW}【$category】${NC}"
      current_category="$category"
    fi
    
    # 显示模块信息
    if [[ "$current_status" == "yes" ]]; then
      if [[ "$is_core" == "yes" ]]; then
        status_mark="${GREEN}[核心-已启用]${NC}"
      else
        status_mark="${GREEN}[已启用]${NC}"
      fi
    else
      if [[ "$is_core" == "yes" ]]; then
        status_mark="${CYAN}[核心-已启用]${NC}"
      else
        status_mark="${RED}[未启用]${NC}"
      fi
    fi
    
    local name_width=35
    if [[ -z "${core_modules:-}" ]]; then
      name_width=25
    fi
    
    printf "  %2d. %-${name_width}s %s\n" "$module_index" "$module_name" "$status_mark"
    echo "      编译选项: $compile_opt"
    echo "      功能说明: $description"
    echo
    
    ((module_index++))
  done
}

# 显示 Stream 模块列表
display_stream_modules() {
  display_modules STREAM_MODULE_LIST STREAM_MODULES
}

# 处理用户模块选择（通用函数）
process_module_selection() {
  local selection="$1"
  local -n module_list="$2"
  local -n module_state="$3"
  local reset_func="$4"
  local valid_selection=false
  
  # 重置所有模块
  $reset_func
  
  # 解析用户输入的数字
  for num in $selection; do
    if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 ]] && [[ "$num" -le ${#module_list[@]} ]]; then
      local selected_module_info="${module_list[$((num-1))]}"
      local selected_module_name
      selected_module_name=$(get_module_name "$selected_module_info")
      module_state["$selected_module_name"]="yes"
      valid_selection=true
    fi
  done
  
  if [[ "$valid_selection" == "true" ]]; then
    print_success "模块配置已更新"
    return 0
  else
    print_warning "输入无效，请重新输入"
    return 1
  fi
}

# 处理 Stream 模块选择
process_stream_module_selection() {
  process_module_selection "$1" STREAM_MODULE_LIST STREAM_MODULES reset_all_stream_modules
}

# ---------------------- HTTP 模块管理函数 ----------------------

# 初始化 HTTP 模块状态
init_http_modules() {
  init_modules HTTP_MODULE_LIST HTTP_MODULES
}

# 设置默认启用的 HTTP 模块（核心模块）
set_default_http_modules() {
  local module
  for module in "${CORE_HTTP_MODULES[@]}"; do
    HTTP_MODULES["$module"]="yes"
    CORE_HTTP_MODULES_MAP["$module"]="yes"
  done
}

# 重置所有 HTTP 模块为未启用（但保留核心模块）
reset_all_http_modules() {
  init_http_modules
  set_default_http_modules
}

# 启用所有 HTTP 模块
enable_all_http_modules() {
  enable_all_modules HTTP_MODULE_LIST HTTP_MODULES
}

# 显示 HTTP 模块列表
display_http_modules() {
  display_modules HTTP_MODULE_LIST HTTP_MODULES CORE_HTTP_MODULES_MAP
}

# 处理用户 HTTP 模块选择
process_http_module_selection() {
  process_module_selection "$1" HTTP_MODULE_LIST HTTP_MODULES reset_all_http_modules
}

# 显示已选择的模块（通用函数）
show_selected_modules() {
  local -n module_list="$1"
  local -n module_state="$2"
  local module_type="$3"
  local -n core_modules="${4:-}"
  local enabled_count=0
  local module_info
  
  echo
  print_info "已选择的 ${module_type} 模块:"
  if [[ -n "${core_modules:-}" ]]; then
    echo
  fi
  
  for module_info in "${module_list[@]}"; do
    local module_name
    module_name=$(get_module_name "$module_info")
    
    if [[ "${module_state[$module_name]:-no}" == "yes" ]]; then
      if [[ -n "${core_modules:-}" ]] && [[ -n "${core_modules[$module_name]:-}" ]]; then
        echo -e "  ${GREEN}✓${NC} ${module_name} ${CYAN}(核心模块)${NC}"
      else
        local compile_opt
        compile_opt=$(get_module_compile_opt "$module_info")
        if [[ -z "${core_modules:-}" ]]; then
          echo -e "  ${GREEN}✓${NC} $module_name ($compile_opt)"
        else
          echo -e "  ${GREEN}✓${NC} ${module_name}"
        fi
      fi
      ((enabled_count++))
    fi
  done
  
  echo
  if [[ $enabled_count -eq 0 ]] && [[ -z "${core_modules:-}" ]]; then
    print_warning "未启用任何可选 ${module_type} 模块（仅使用核心模块）"
  else
    print_info "共启用 $enabled_count 个 ${module_type} 模块"
  fi
}

# 显示已选择的 HTTP 模块
show_selected_http_modules() {
  show_selected_modules HTTP_MODULE_LIST HTTP_MODULES "HTTP" CORE_HTTP_MODULES_MAP
}

# 显示已选择的 Stream 模块
show_selected_stream_modules() {
  show_selected_modules STREAM_MODULE_LIST STREAM_MODULES "Stream"
}

# ---------------------- 工具函数 ----------------------

# 获取 CPU 核数用于并行编译
get_cpu_cores() {
  local cores
  if command -v nproc >/dev/null 2>&1; then
    cores=$(nproc)
  elif [[ -f /proc/cpuinfo ]]; then
    cores=$(grep -c "^processor" /proc/cpuinfo)
  else
    cores=1
  fi
  
  # 确保至少为 1，且不超过 8（避免过度占用系统资源）
  if [[ -z "$cores" ]] || [[ "$cores" -lt 1 ]]; then
    cores=1
  elif [[ "$cores" -gt 8 ]]; then
    cores=8
  fi
  
  echo "$cores"
}

# 处理用户输入（通用函数）
prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local env_var="${3:-}"
  local result
  
  # 如果提供了环境变量且已设置，直接使用
  if [[ -n "$env_var" ]] && [[ -n "${!env_var:-}" ]]; then
    result="${!env_var}"
    print_info "使用环境变量 ${env_var}: $result"
    echo "$result"
    return 0
  fi
  
  # 否则提示用户输入
  while true; do
    read -rp "$prompt" input
    input="${input:-$default}"
    case "${input,,}" in
      y|yes)
        echo "yes"
        return 0
        ;;
      n|no|"")
        echo "no"
        return 0
        ;;
      *)
        print_warning "请输入 y 或 n"
        ;;
    esac
  done
}

# ---------------------- 下载和解压函数 ----------------------

# 下载 Nginx 源码包
download_nginx_source() {
  local version="$1"
  local build_dir="$2"
  local tarball="nginx-${version}.tar.gz"
  local url="http://nginx.org/download/${tarball}"
  
  print_info "正在下载: $url"
  
  if command -v wget >/dev/null 2>&1; then
    if ! wget -q --show-progress "$url" -O "${build_dir}/${tarball}"; then
      print_error "下载失败，请检查网络连接"
      return 1
    fi
  elif command -v curl >/dev/null 2>&1; then
    if ! curl -L -o "${build_dir}/${tarball}" --progress-bar "$url"; then
      print_error "下载失败，请检查网络连接"
      return 1
    fi
  else
    print_error "未找到 wget 或 curl"
    return 1
  fi
  
  print_success "下载完成"
  echo "$tarball"
}

# 解压 Nginx 源码包
extract_nginx_source() {
  local build_dir="$1"
  local tarball="$2"
  local version="$3"
  
  print_info "正在解压: $tarball"
  
  if ! tar -xzf "${build_dir}/${tarball}" -C "$build_dir"; then
    print_error "解压失败"
    return 1
  fi
  
  print_success "解压完成"
  echo "${build_dir}/nginx-${version}"
}

# ---------------------- 输入验证函数 ----------------------

# 验证路径格式
validate_path() {
  local path="$1"
  local path_type="$2"
  
  if [[ -z "$path" ]]; then
    print_error "${path_type}路径不能为空"
    return 1
  fi
  
  # 检查路径是否包含非法字符
  if [[ "$path" =~ [^a-zA-Z0-9/._-] ]]; then
    print_error "${path_type}路径包含非法字符: $path"
    return 1
  fi
  
  return 0
}

# 验证并创建目录
ensure_directory() {
  local dir_path="$1"
  local dir_type="$2"
  
  if ! validate_path "$dir_path" "$dir_type"; then
    return 1
  fi
  
  local parent_dir
  parent_dir=$(dirname "$dir_path")
  
  if [[ ! -d "$parent_dir" ]]; then
    print_info "创建目录: $parent_dir"
    mkdir -p "$parent_dir" || {
      print_error "无法创建目录: $parent_dir"
      return 1
    }
  fi
  
  return 0
}

# ---------------------- 权限检查 ----------------------

if [[ $EUID -ne 0 ]]; then
  print_error "请使用 root 运行[例如 sudo $0]"
  exit 1
fi

print_section "1/5 环境检测与依赖检查"

# ---------------------- 包管理器检测 ----------------------

if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
  UPDATE_CMD="apt-get update -y"
  INSTALL_CMD="apt-get install -y"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
  UPDATE_CMD="dnf makecache -y"
  INSTALL_CMD="dnf install -y"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
  UPDATE_CMD="yum makecache -y"
  INSTALL_CMD="yum install -y"
else
  print_error "未检测到受支持的包管理器[apt/dnf/yum]，无法继续。"
  exit 1
fi

print_success "检测到包管理器: $PKG_MGR"

# ---------------------- 系统兼容性检查 ----------------------

print_subsection "系统兼容性检查"

# 检查 GCC 版本（Nginx 需要 GCC 4.8+）
if ! command -v gcc >/dev/null 2>&1; then
  print_warning "未检测到 GCC 编译器，将在后续步骤中安装"
else
  GCC_VERSION=$(gcc --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  GCC_MAJOR=$(echo "$GCC_VERSION" | cut -d. -f1)
  GCC_MINOR=$(echo "$GCC_VERSION" | cut -d. -f2)
  
  if [[ -n "$GCC_VERSION" ]]; then
    if (( GCC_MAJOR > 4 )) || (( GCC_MAJOR == 4 && GCC_MINOR >= 8 )); then
      print_success "GCC 版本检查通过: $GCC_VERSION"
    else
      print_error "GCC 版本过低: $GCC_VERSION，需要 4.8 或更高版本"
      exit 1
    fi
  else
    print_warning "无法确定 GCC 版本，将继续安装"
  fi
fi

# 检查 Make
if ! command -v make >/dev/null 2>&1; then
  print_warning "未检测到 Make，将在后续步骤中安装"
else
  print_success "Make 已安装"
fi

# 检查 wget 和 curl
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  print_error "未检测到 wget 或 curl，无法下载源码"
  exit 1
fi

print_success "基础工具检查完成"

# ---------------------- 安装编译依赖 ----------------------

print_subsection "安装编译依赖"

print_info "正在更新软件包缓存..."
bash -c "$UPDATE_CMD" >/dev/null 2>&1 || true

if [[ "$PKG_MGR" == "apt" ]]; then
  print_info "正在安装编译依赖: $REQUIRED_BUILD_DEPS_APT"
  export DEBIAN_FRONTEND=noninteractive
  bash -c "$INSTALL_CMD $REQUIRED_BUILD_DEPS_APT" || {
    print_error "依赖安装失败，请检查网络连接和软件源配置"
    exit 1
  }
else
  print_info "正在安装编译依赖: $REQUIRED_BUILD_DEPS_YUM"
  bash -c "$INSTALL_CMD $REQUIRED_BUILD_DEPS_YUM" || {
    print_error "依赖安装失败，请检查网络连接和软件源配置"
    exit 1
  }
fi

print_success "编译依赖安装完成"

# ---------------------- 获取最新版本 ----------------------

print_section "2/5 获取最新版本信息"

print_info "正在获取 Nginx 最新稳定版本..."

# 从官方下载页面获取最新稳定版本
get_latest_nginx_version() {
  local version=""
  
  if command -v curl >/dev/null 2>&1; then
    version=$(curl -s --connect-timeout 10 --max-time 30 http://nginx.org/en/download.html 2>/dev/null | \
      grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/nginx-//')
  elif command -v wget >/dev/null 2>&1; then
    version=$(wget -q --timeout=10 -O- http://nginx.org/en/download.html 2>/dev/null | \
      grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/nginx-//')
  fi
  
  echo "$version"
}

NGINX_VERSION=$(get_latest_nginx_version)

if [[ -z "$NGINX_VERSION" ]]; then
  print_error "无法获取最新版本信息，请检查网络连接"
  exit 1
fi

# 验证版本号格式
if [[ ! "$NGINX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  print_error "获取的版本号格式无效: $NGINX_VERSION"
  exit 1
fi

print_success "检测到最新稳定版本: $NGINX_VERSION"

# ---------------------- 用户配置输入 ----------------------

print_section "3/5 配置安装路径"

# 从环境变量读取或提示用户输入
if [[ -n "${NGINX_PREFIX:-}" ]]; then
  NGINX_PREFIX="${NGINX_PREFIX}"
  print_info "使用环境变量 NGINX_PREFIX: $NGINX_PREFIX"
else
  read -rp "请输入安装路径前缀[默认: $DEFAULT_PREFIX]: " prefix_input
  NGINX_PREFIX="${prefix_input:-$DEFAULT_PREFIX}"
fi

if [[ -n "${NGINX_CONF_PATH:-}" ]]; then
  NGINX_CONF_PATH="${NGINX_CONF_PATH}"
  print_info "使用环境变量 NGINX_CONF_PATH: $NGINX_CONF_PATH"
else
  read -rp "请输入配置文件路径[默认: $DEFAULT_CONF_PATH]: " conf_input
  NGINX_CONF_PATH="${conf_input:-$DEFAULT_CONF_PATH}"
fi

# 自动设置 PID 和日志路径
NGINX_PID_PATH="${NGINX_PID_PATH:-$DEFAULT_PID_PATH}"
NGINX_LOG_PATH="${NGINX_LOG_PATH:-$DEFAULT_LOG_PATH}"

# 验证路径
if ! validate_path "$NGINX_PREFIX" "安装路径"; then
  exit 1
fi

if ! validate_path "$NGINX_CONF_PATH" "配置文件路径"; then
  exit 1
fi

# 询问是否安装邮件模块
echo
print_info "邮件模块包含以下功能:"
echo "  - ngx_mail_core_module (邮件核心模块)"
echo "  - ngx_mail_auth_http_module (邮件认证模块)"
echo "  - ngx_mail_proxy_module (邮件代理模块)"
echo "  - ngx_mail_realip_module (邮件真实IP模块)"
echo "  - ngx_mail_ssl_module (邮件SSL模块)"
echo "  - ngx_mail_imap_module (IMAP协议支持)"
echo "  - ngx_mail_pop3_module (POP3协议支持)"
echo "  - ngx_mail_smtp_module (SMTP协议支持)"
echo

ENABLE_MAIL_MODULES=$(prompt_yes_no "是否安装邮件模块? [y/N]: " "N" "ENABLE_MAIL_MODULES")

# ---------------------- Stream 模块配置 ----------------------

print_subsection "配置 Stream (TCP/UDP) 模块"

echo
print_info "Nginx Stream 模块用于四层（TCP/UDP）反向代理和负载均衡"
echo
print_info "核心模块（--with-stream）将自动启用，包含以下基础功能:"
echo "  - ngx_stream_core_module (Stream 核心模块)"
echo "  - ngx_stream_upstream_module (四层 upstream 功能)"
echo "  - ngx_stream_proxy_module (四层反向代理)"
echo "  - ngx_stream_access_module (基于 IP 的访问控制)"
echo "  - ngx_stream_map_module (变量映射)"
echo "  - ngx_stream_log_module (访问日志)"
echo "  - ngx_stream_return_module (直接返回数据)"
echo

# 定义可选的 Stream 模块
# 格式: "模块名|编译选项|分类|描述"
# 注意: 以下模块均为标准 Nginx 中可用的模块
#       某些高级功能（如 keyval、mqtt、upstream_hc、zone_sync）可能需要 Nginx Plus 或第三方模块
STREAM_MODULE_LIST=(
  "stream_ssl|--with-stream_ssl_module|访问控制与安全|四层 SSL/TLS 终止，提供 ssl_certificate、ssl_protocols 等指令"
  "stream_ssl_preread|--with-stream_ssl_preread_module|访问控制与安全|预读 ClientHello，提取 SNI/ALPN 用于路由（不终止 TLS）"
  "stream_realip|--with-stream_realip_module|访问控制与安全|处理真实客户端 IP（通过 PROXY protocol）"
  "stream_limit_conn|--with-stream_limit_conn_module|访问控制与安全|连接数限制，防止客户端占满连接"
  "stream_geoip|--with-stream_geoip_module=dynamic|监控、日志与地理|使用 GeoIP 数据库进行地理位置查询（需要 libmaxminddb）"
  "stream_split_clients|--with-stream_split_clients_module|配置辅助与分流|流量切分（A/B 测试、灰度发布）"
  "stream_set|--with-stream_set_module|配置辅助与分流|提供 set 指令定义变量值"
  "stream_geo|--with-stream_geo_module|监控、日志与地理|基于 IP 的地理/标签映射"
)

# 默认启用的模块（常用模块）
DEFAULT_STREAM_MODULES=("stream_ssl" "stream_ssl_preread" "stream_realip")

# 初始化 Stream 模块状态
init_stream_modules
set_default_stream_modules

# 处理模块配置交互（通用函数）
configure_modules_interactive() {
  local module_type="$1"
  local display_func="$2"
  local reset_func="$3"
  local set_default_func="$4"
  local enable_all_func="$5"
  local process_selection_func="$6"
  local default_msg="$7"
  
  local custom_input
  custom_input=$(prompt_yes_no "是否自定义配置 ${module_type} 模块? [Y/n]: " "Y")
  
  if [[ "$custom_input" == "yes" ]]; then
    # 显示所有可选模块
    echo
    print_info "可选 ${module_type} 模块列表:"
    echo
    $display_func
    
    # 让用户选择模块
    echo
    print_info "请选择要启用的模块（输入模块编号，多个用空格分隔，如: 1 2 3）"
    if [[ "$module_type" == "HTTP" ]]; then
      print_info "输入 'all' 启用所有模块，输入 'default' 使用默认配置（仅核心模块），输入 'skip' 跳过"
    else
      print_info "输入 'all' 启用所有模块，输入 'default' 使用默认配置，输入 'skip' 跳过"
    fi
    read -rp "您的选择: " module_selection
    
    case "${module_selection,,}" in
      skip)
        print_info "使用当前配置"
        ;;
      default)
        $reset_func
        if [[ -n "$set_default_func" ]]; then
          $set_default_func
        fi
        print_success "已重置为默认配置"
        ;;
      all)
        $enable_all_func
        print_success "已启用所有模块"
        ;;
      *)
        if ! $process_selection_func "$module_selection"; then
          print_warning "配置失败，使用当前配置"
        fi
        ;;
    esac
  else
    print_info "$default_msg"
  fi
}

# 询问用户是否要自定义配置 Stream 模块
echo
configure_modules_interactive \
  "Stream" \
  "display_stream_modules" \
  "reset_all_stream_modules" \
  "set_default_stream_modules" \
  "enable_all_stream_modules" \
  "process_stream_module_selection" \
  "使用默认 Stream 模块配置"

# 显示最终选择的模块
show_selected_stream_modules

# ---------------------- HTTP 模块配置 ----------------------

print_subsection "配置 HTTP 模块"

echo
print_info "Nginx HTTP 模块用于七层（HTTP/HTTPS）代理、负载均衡和内容处理"
echo
print_info "核心模块将自动启用，包含以下基础功能:"
echo "  - ngx_http_core_module (HTTP 核心模块，server/location 配置、请求路由等)"
echo

# 定义 HTTP 模块列表
# 格式: "模块名|编译选项|分类|描述"
# 注意: 某些模块可能需要 Nginx Plus 或第三方扩展
HTTP_MODULE_LIST=(
  # 一、核心与访问控制
  "http_core|内置|核心与访问控制|HTTP 核心模块，负责 server/location 配置、请求路由、超时、缓冲区等基本能力"
  "http_access|--with-http_access_module|核心与访问控制|用 allow/deny 按 IP 控制访问权限"
  "http_auth_basic|--with-http_auth_basic_module|核心与访问控制|基础认证（Basic Auth），用 .htpasswd 之类的用户密码文件"
  "http_auth_jwt|第三方|核心与访问控制|使用 JWT 进行认证，验证 Authorization 里的 JWT Token（需要第三方模块）"
  "http_auth_request|--with-http_auth_request_module|核心与访问控制|把认证逻辑反向代理给后端（子请求），由后端返回 2xx/401/403 决定是否放行"
  "http_auth_require|第三方|核心与访问控制|更复杂的授权控制（基于变量表达式），通常配合 JWT/OIDC 使用（需要第三方模块）"
  "http_realip|--with-http_realip_module|核心与访问控制|从 X-Forwarded-For/proxy_protocol 等头里获取真实客户端 IP"
  "http_referer|内置|核心与访问控制|通过 Referer 防盗链，只允许指定来源"
  "http_secure_link|--with-http_secure_link_module|核心与访问控制|防盗链/链接签名，校验 URL 中的签名参数，常用于下载、视频"
  "http_userid|内置|核心与访问控制|生成或管理用户 ID Cookie（如 uid），用于用户跟踪、统计"
  "http_limit_conn|--with-http_limit_conn_module|核心与访问控制|限制并发连接数，防止单 IP/单 key 把连接占满"
  "http_limit_req|--with-http_limit_req_module|核心与访问控制|限制请求速率，简单的 QPS 限流"
  
  # 二、配置增强与变量处理
  "http_map|内置|配置增强与变量处理|用 map 指令进行变量映射（类似条件表），常用于基于 Host/URI/IP 生成变量"
  "http_split_clients|内置|配置增强与变量处理|按 hash 做流量切分（A/B Test、灰度发布）"
  "http_keyval|第三方|配置增强与变量处理|key-value 动态配置（一般用于运行时可变的配置项，需要 Nginx Plus 或第三方）"
  
  # 三、日志与监控
  "http_log|内置|日志与监控|标准访问日志模块，access_log、log_format 都在这里"
  "http_stub_status|--with-http_stub_status_module|日志与监控|简单状态页 /status，展示连接数、请求数等统计"
  "http_status|第三方|日志与监控|更强的状态统计接口（NGINX Plus 的高级状态模块）"
  "http_api|第三方|日志与监控|提供基于 REST 的管理/监控 API（一般是 NGINX Plus）"
  
  # 四、代理/网关/上游相关
  "http_proxy|内置|代理/网关/上游相关|标准反向代理模块，proxy_pass 等"
  "http_grpc|--with-http_v2_module|代理/网关/上游相关|反向代理 gRPC 服务（通过 HTTP/2）"
  "http_uwsgi|内置|代理/网关/上游相关|转发到 uWSGI 应用（Python 等）"
  "http_fastcgi|内置|代理/网关/上游相关|通过 FastCGI 与 PHP-FPM 等交互"
  "http_scgi|内置|代理/网关/上游相关|通过 SCGI 与后端应用交互"
  "http_memcached|内置|代理/网关/上游相关|直接访问 Memcached 缓存，把 key 映射为响应"
  "http_upstream|内置|代理/网关/上游相关|upstream 负载均衡配置基础模块"
  
  # 五、压缩与内容传输优化
  "http_gzip|内置|压缩与内容传输优化|在线 Gzip 压缩响应"
  "http_gzip_static|--with-http_gzip_static_module|压缩与内容传输优化|直接发送已经压缩好的 .gz 静态文件"
  "http_gunzip|--with-http_gunzip_module|压缩与内容传输优化|先解压 Gzip 响应再返回（例如后端只支持 Gzip 时）"
  "http_slice|--with-http_slice_module|压缩与内容传输优化|把一个大文件切片分段请求，支持断点续传、分片缓存"
  "http_sub|--with-http_sub_module|压缩与内容传输优化|在响应体中做字符串替换（简单内容重写）"
  "http_addition|--with-http_addition_module|压缩与内容传输优化|在响应前或后再插入额外内容（前后拼接）"
  
  # 六、TLS/HTTP 协议
  "http_ssl|--with-http_ssl_module|TLS/HTTP 协议|HTTPS/TLS 支持（证书、协议版本、密码套件等）"
  "http_v2|--with-http_v2_module|TLS/HTTP 协议|HTTP/2 协议支持"
  "http_v3|第三方|TLS/HTTP 协议|HTTP/3/QUIC 支持（需要第三方模块，如 Cloudflare quiche）"
  
  # 七、索引、目录、静态文件
  "http_index|内置|索引、目录、静态文件|自动匹配 index.html 等默认首页"
  "http_random_index|--with-http_random_index_module|索引、目录、静态文件|在目录中随机选择文件作为 index（较少用）"
  "http_autoindex|内置|索引、目录、静态文件|开启目录浏览列表"
  "http_empty_gif|内置|索引、目录、静态文件|返回一个 1x1 的空 GIF（早期用于统计/像素追踪）"
  
  # 八、字符集与内容处理
  "http_charset|内置|字符集与内容处理|设置/转换内容编码（如 UTF-8/GBK）"
  "http_headers|内置|字符集与内容处理|添加、设置、删除响应头（add_header 等）"
  "http_browser|内置|字符集与内容处理|根据 User-Agent 判断浏览器类型，做差异化处理"
  "http_ssi|内置|字符集与内容处理|服务端包含（Server Side Include），在 HTML 中包含子文件"
  "http_rewrite|内置|字符集与内容处理|rewrite、if 等基于正则和变量的重写逻辑，Nginx 里最关键的逻辑控制模块之一"
  "http_perl|--with-http_perl_module|字符集与内容处理|用 Perl 脚本处理请求（现在比较少用）"
  "http_js|第三方|字符集与内容处理|用 njs（NGINX 自家 JS）写逻辑，代替/扩展 rewrite/access 等（需要 njs 模块）"
  "http_xslt|--with-http_xslt_module=dynamic|字符集与内容处理|用 XSLT 把 XML 转换成 HTML 等"
  "http_image_filter|--with-http_image_filter_module=dynamic|字符集与内容处理|图片缩放、裁剪、水印等简单图像处理"
  
  # 九、缓存、镜像、特殊转发
  "http_mirror|内置|缓存、镜像、特殊转发|镜像请求到另一个后端（不影响主响应），常用于灰度、监控"
  
  # 十、媒体/流媒体处理
  "http_flv|--with-http_flv_module|媒体/流媒体处理|支持 FLV 视频的伪流式（拖动进度条）"
  "http_mp4|--with-http_mp4_module|媒体/流媒体处理|支持 MP4 的伪流式点播，支持按区间返回"
  "http_hls|第三方|媒体/流媒体处理|支持 HLS（HTTP Live Streaming）流媒体切片（需要第三方模块）"
  
  # 十一、Web 身份与单点登录
  "http_oidc|第三方|Web 身份与单点登录|OpenID Connect（OIDC）模块，用于对接 OAuth2/OIDC（如 Keycloak、Auth0 等）做登录、单点登录（需要第三方模块）"
  
  # 十二、其它辅助模块
  "http_dav|--with-http_dav_module|其它辅助模块|支持 WebDAV（远程文件管理、上传、删除）"
  "http_geo|内置|其它辅助模块|自己维护 IP→地区的映射表，生成位置信息变量"
  "http_geoip|--with-http_geoip_module=dynamic|其它辅助模块|通过 GeoIP 数据库识别用户地理位置（老版，多已被 geoip2 替代）"
)

# 定义核心 HTTP 模块（默认必须启用）
CORE_HTTP_MODULES=(
  "http_core"
  "http_proxy"
  "http_upstream"
  "http_log"
  "http_index"
  "http_autoindex"
  "http_charset"
  "http_headers"
  "http_rewrite"
  "http_map"
  "http_referer"
  "http_userid"
  "http_empty_gif"
  "http_browser"
  "http_ssi"
  "http_gzip"
  "http_mirror"
  "http_geo"
  "http_fastcgi"
  "http_uwsgi"
  "http_scgi"
  "http_memcached"
)

# 初始化 HTTP 模块状态
init_http_modules
set_default_http_modules

# 询问用户是否要自定义配置 HTTP 模块
echo
configure_modules_interactive \
  "HTTP" \
  "display_http_modules" \
  "reset_all_http_modules" \
  "" \
  "enable_all_http_modules" \
  "process_http_module_selection" \
  "使用默认 HTTP 模块配置（仅核心模块）"

# 显示最终选择的模块
show_selected_http_modules

print_success "安装路径: $NGINX_PREFIX"
print_success "配置文件: $NGINX_CONF_PATH"
print_success "PID 文件: $NGINX_PID_PATH"
print_success "日志目录: $NGINX_LOG_PATH"
if [[ "$ENABLE_MAIL_MODULES" == "yes" ]]; then
  print_success "邮件模块: 已启用"
else
  print_info "邮件模块: 未启用"
fi

# ---------------------- 下载源码 ----------------------

print_section "4/5 下载与编译安装"

print_subsection "下载源码包"

# 创建临时编译目录
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

NGINX_TARBALL=$(download_nginx_source "$NGINX_VERSION" "$BUILD_DIR")
if [[ -z "$NGINX_TARBALL" ]]; then
  exit 1
fi

# ---------------------- 解压源码 ----------------------

print_subsection "解压源码包"

NGINX_SOURCE_DIR=$(extract_nginx_source "$BUILD_DIR" "$NGINX_TARBALL" "$NGINX_VERSION")
if [[ -z "$NGINX_SOURCE_DIR" ]] || [[ ! -d "$NGINX_SOURCE_DIR" ]]; then
  exit 1
fi

cd "$NGINX_SOURCE_DIR" || exit 1

# ---------------------- 配置编译选项 ----------------------

print_subsection "配置编译选项"

# 创建必要的目录
if ! ensure_directory "$NGINX_CONF_PATH" "配置文件"; then
  exit 1
fi

if ! ensure_directory "$NGINX_PID_PATH" "PID文件"; then
  exit 1
fi

if ! ensure_directory "$NGINX_LOG_PATH/error.log" "日志目录"; then
  exit 1
fi

# 获取 CPU 核数用于并行编译
CPU_CORES=$(get_cpu_cores)
print_info "使用 $CPU_CORES 个 CPU 核心进行编译"

# 配置编译选项（基础选项）
CONFIGURE_OPTS=(
  --prefix="$NGINX_PREFIX"
  --conf-path="$NGINX_CONF_PATH"
  --pid-path="$NGINX_PID_PATH"
  --error-log-path="$NGINX_LOG_PATH/error.log"
  --http-log-path="$NGINX_LOG_PATH/access.log"
  --with-threads
  --with-stream
  --with-file-aio
)

# ---------------------- 编译选项构建函数 ----------------------

# 添加模块编译选项（通用函数）
add_module_options() {
  local -n module_list="$1"
  local -n module_state="$2"
  local module_type="$3"
  local skip_builtin="${4:-false}"
  local modules_count=0
  local module_info
  
  for module_info in "${module_list[@]}"; do
    local module_name compile_opt
    module_name=$(get_module_name "$module_info")
    compile_opt=$(get_module_compile_opt "$module_info")
    
    # 跳过内置模块和第三方模块（如果指定）
    if [[ "$skip_builtin" == "true" ]]; then
      if [[ "$compile_opt" == "内置" ]] || [[ "$compile_opt" == "第三方" ]]; then
        continue
      fi
    fi
    
    if [[ "${module_state[$module_name]:-no}" == "yes" ]]; then
      CONFIGURE_OPTS+=("$compile_opt")
      ((modules_count++))
    fi
  done
  
  if [[ $modules_count -gt 0 ]]; then
    print_info "已添加 $modules_count 个 ${module_type} 模块编译选项"
  fi
}

# 添加 Stream 模块编译选项
add_stream_module_options() {
  add_module_options STREAM_MODULE_LIST STREAM_MODULES "Stream" false
}

# 添加 HTTP 模块编译选项
add_http_module_options() {
  add_module_options HTTP_MODULE_LIST HTTP_MODULES "HTTP" true
}

# 添加邮件模块编译选项
add_mail_module_options() {
  if [[ "$ENABLE_MAIL_MODULES" == "yes" ]]; then
    CONFIGURE_OPTS+=(
      --with-mail
      --with-mail_ssl_module
      --with-mail_imap_module
      --with-mail_pop3_module
      --with-mail_smtp_module
    )
    print_info "已添加邮件模块编译选项"
  fi
}

# 添加 Stream、HTTP 和邮件模块编译选项
add_stream_module_options
add_http_module_options
add_mail_module_options

print_info "执行 configure..."
./configure "${CONFIGURE_OPTS[@]}" || {
  print_error "配置失败，请检查依赖是否完整安装"
  exit 1
}

print_success "配置完成"

# ---------------------- 编译 ----------------------

print_subsection "编译源码"

print_info "开始编译（这可能需要几分钟）..."
make -j"$CPU_CORES" || {
  print_error "编译失败"
  exit 1
}

print_success "编译完成"

# ---------------------- 安装 ----------------------

print_subsection "安装 Nginx"

print_info "正在安装到: $NGINX_PREFIX"
make install || {
  print_error "安装失败"
  exit 1
}

print_success "安装完成"

# ---------------------- 创建 systemd 服务文件（可选） ----------------------

print_section "5/5 完成与验证"

print_subsection "创建 systemd 服务文件"

NGINX_SERVICE_FILE="/etc/systemd/system/nginx.service"

if [[ ! -f "$NGINX_SERVICE_FILE" ]]; then
  cat > "$NGINX_SERVICE_FILE" <<EOF
[Unit]
Description=The nginx HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=$NGINX_PID_PATH
ExecStartPre=$NGINX_PREFIX/sbin/nginx -t -c $NGINX_CONF_PATH
ExecStart=$NGINX_PREFIX/sbin/nginx -c $NGINX_CONF_PATH
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  print_success "systemd 服务文件已创建: $NGINX_SERVICE_FILE"
else
  print_info "systemd 服务文件已存在，跳过创建"
fi

# ---------------------- 验证安装 ----------------------

print_subsection "验证安装"

if [[ -f "$NGINX_PREFIX/sbin/nginx" ]]; then
  INSTALLED_VERSION=$("$NGINX_PREFIX/sbin/nginx" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  print_success "Nginx 已成功安装"
  print_info "版本: $INSTALLED_VERSION"
  print_info "可执行文件: $NGINX_PREFIX/sbin/nginx"
  print_info "配置文件: $NGINX_CONF_PATH"
  
  # 测试配置文件
  if "$NGINX_PREFIX/sbin/nginx" -t -c "$NGINX_CONF_PATH" 2>/dev/null; then
    print_success "配置文件语法检查通过"
  else
    print_warning "配置文件语法检查失败，请手动检查: $NGINX_CONF_PATH"
  fi
else
  print_error "安装验证失败，可执行文件不存在"
  exit 1
fi

# ---------------------- 清理临时文件 ----------------------

print_subsection "清理临时文件"

if [[ -d "$BUILD_DIR" ]]; then
  rm -rf "$BUILD_DIR"
  print_success "临时文件已清理"
else
  print_info "无需清理临时文件"
fi

# ---------------------- 显示摘要 ----------------------

echo
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│                     安装完成                                 │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "版本" "$INSTALLED_VERSION"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "安装路径" "$NGINX_PREFIX"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "配置文件" "$NGINX_CONF_PATH"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "PID 文件" "$NGINX_PID_PATH"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "日志目录" "$NGINX_LOG_PATH"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│${NC}  启动命令: ${GREEN}$NGINX_PREFIX/sbin/nginx${NC}                              ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  或使用 systemd: ${GREEN}systemctl start nginx${NC}                        ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  测试配置: ${GREEN}$NGINX_PREFIX/sbin/nginx -t${NC}                          ${CYAN}│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo