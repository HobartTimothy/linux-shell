#!/usr/bin/env bash
#
# ============================================================
# 说明: Java 运行环境自动安装脚本（支持 Eclipse Temurin / Amazon Corretto / OpenJDK / GraalVM）
#
# 特性:
#   - 支持选择发行版: Eclipse Temurin、Amazon Corretto、OpenJDK、GraalVM
#   - 支持选择镜像类型: JDK / JRE（部分发行版仅支持 JDK）
#   - 通过 wget 自动下载对应发行版的「最新稳定版本」tar.gz 包
#   - 自动解压安装到 /opt/java/<vendor>/ 目录
#   - 自动设置 JAVA_HOME 和 PATH（写入 /etc/profile.d/java.sh）
#
# 环境变量（非交互模式可用）:
#   JAVA_VENDOR   : temurin | corretto | openjdk | graalvm
#   JAVA_TYPE     : jdk | jre
#   JAVA_FEATURE  : 17（目前主要针对 17，可按需扩展）
#
###############################################################

set -euo pipefail

# ---------------------- 终端颜色定义 ----------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# ---------------------- 权限与工具检查 ----------------------

if [[ $EUID -ne 0 ]]; then
  print_error "请使用 root 运行本脚本（例如: sudo $0）"
  exit 1
fi

if ! command -v wget >/dev/null 2>&1; then
  print_error "未检测到 wget，请先安装 wget 后再执行。"
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  print_error "未检测到 tar，请先安装 tar 后再执行。"
  exit 1
fi

# ---------------------- 全局变量 ----------------------

JAVA_VENDOR="${JAVA_VENDOR:-}"
JAVA_TYPE="${JAVA_TYPE:-}"
JAVA_FEATURE="${JAVA_FEATURE:-17}"

INSTALL_ROOT="/opt/java"
TMP_DIR="/tmp/java_install"

# Maven 相关全局变量
INSTALL_MAVEN="${INSTALL_MAVEN:-}"   # y / n，非交互模式可用
MAVEN_INSTALL_ROOT="/opt/maven"
MAVEN_TMP_DIR="/tmp/maven_install"

# Web 服务器相关全局变量
INSTALL_WEB_SERVER="${INSTALL_WEB_SERVER:-}"      # y / n，非交互模式可用
WEB_SERVER_CHOICE="${WEB_SERVER_CHOICE:-}"        # tomcat | jetty | undertow
WEB_SERVER_INSTALL_PATH="${WEB_SERVER_INSTALL_PATH:-/opt/webserver}"
WEB_TMP_DIR="/tmp/webserver_install"

# ---------------------- 架构与系统检测 ----------------------

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      echo "x64"
      ;;
    aarch64|arm64)
      echo "aarch64"
      ;;
    *)
      print_error "暂不支持的架构: $arch"
      exit 1
      ;;
  esac
}

detect_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Linux)
      echo "linux"
      ;;
    *)
      print_error "当前脚本仅支持 Linux 系统，检测到: $os"
      exit 1
      ;;
  esac
}

ARCH="$(detect_arch)"
OS="$(detect_os)"

# ---------------------- 交互选择 ----------------------

prompt_vendor() {
  local choice

  if [[ -n "$JAVA_VENDOR" ]]; then
    case "${JAVA_VENDOR,,}" in
      temurin|corretto|openjdk|graalvm)
        JAVA_VENDOR="${JAVA_VENDOR,,}"
        print_info "使用环境变量 JAVA_VENDOR: $JAVA_VENDOR"
        return 0
        ;;
      *)
        print_warning "无效的 JAVA_VENDOR=${JAVA_VENDOR}，将进入交互式选择。"
        ;;
    esac
  fi

  echo "请选择要安装的 Java 发行版:"
  echo "  1) Eclipse Temurin (Adoptium, 社区常用 LTS 版本)"
  echo "  2) Amazon Corretto (AWS 维护，针对云环境优化)"
  echo "  3) OpenJDK 官方构建（仅 JDK）"
  echo "  4) GraalVM Community (JDK + 原生镜像等高级特性，实验/高级场景)"
  echo "  q) 退出"
  echo

  while true; do
    read -rp "请输入选项 [1/2/3/4/q]: " choice
    case "${choice,,}" in
      1) JAVA_VENDOR="temurin"; break ;;
      2) JAVA_VENDOR="corretto"; break ;;
      3) JAVA_VENDOR="openjdk"; break ;;
      4) JAVA_VENDOR="graalvm"; break ;;
      q)
        print_info "用户选择退出，未进行任何安装操作。"
        exit 0
        ;;
      *)
        print_warning "无效输入，请输入 1 / 2 / 3 / 4 / q"
        ;;
    esac
  done
}

prompt_type() {
  local choice

  if [[ -n "$JAVA_TYPE" ]]; then
    case "${JAVA_TYPE,,}" in
      jdk|jre)
        JAVA_TYPE="${JAVA_TYPE,,}"
        print_info "使用环境变量 JAVA_TYPE: $JAVA_TYPE"
        return 0
        ;;
      *)
        print_warning "无效的 JAVA_TYPE=${JAVA_TYPE}，将进入交互式选择。"
        ;;
    esac
  fi

  echo "请选择要安装的镜像类型:"
  echo "  1) JDK (开发环境，包含 javac 等工具)"
  echo "  2) JRE (仅运行环境)"
  echo "  q) 退出"
  echo

  while true; do
    read -rp "请输入选项 [1/2/q]: " choice
    case "${choice,,}" in
      1) JAVA_TYPE="jdk"; break ;;
      2) JAVA_TYPE="jre"; break ;;
      q)
        print_info "用户选择退出，未进行任何安装操作。"
        exit 0
        ;;
      *)
        print_warning "无效输入，请输入 1 / 2 / q"
        ;;
    esac
  done
}

prompt_feature() {
  local input

  # 若已通过环境变量指定，则先校验范围
  if [[ -n "$JAVA_FEATURE" ]]; then
    if [[ "$JAVA_FEATURE" =~ ^[0-9]+$ ]] && (( JAVA_FEATURE >= 8 && JAVA_FEATURE <= 25 )); then
      print_info "使用环境变量 JAVA_FEATURE: $JAVA_FEATURE"
      return 0
    else
      print_warning "无效的 JAVA_FEATURE=${JAVA_FEATURE}（支持 8-25），将进入交互式输入。"
    fi
  fi

  echo "请选择要安装的 Java 主版本号 (8-25):"
  echo "  示例: 8, 11, 17, 21 等，默认 17"
  echo

  while true; do
    read -rp "请输入版本号 [8-25] (直接回车使用 17): " input
    if [[ -z "$input" ]]; then
      JAVA_FEATURE=17
      break
    fi

    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 8 && input <= 25 )); then
      JAVA_FEATURE="$input"
      break
    else
      print_warning "版本号无效，仅支持 8-25，请重新输入。"
    fi
  done
}

# ---------------------- 下载 URL 生成 ----------------------

build_download_url() {
  local vendor="$1"
  local type="$2"
  local feature="$3"
  local os="$4"
  local arch="$5"

  case "$vendor" in
    temurin)
      # Adoptium API 提供最新 GA 版本的直接二进制下载，返回 tar.gz 内容
      # 示例:
      #   JDK: https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk
      #   JRE: https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jre/hotspot/normal/eclipse?project=jdk
      echo "https://api.adoptium.net/v3/binary/latest/${feature}/ga/${os}/${arch}/${type}/hotspot/normal/eclipse?project=jdk"
      ;;
    corretto)
      # Amazon Corretto 使用固定「latest」下载链接
      # 示例:
      #   JDK: https://corretto.aws/downloads/latest/amazon-corretto-17-x64-linux-jdk.tar.gz
      #   JRE: https://corretto.aws/downloads/latest/amazon-corretto-17-x64-linux-jre.tar.gz
      local arch_tag
      case "$arch" in
        x64) arch_tag="x64" ;;
        aarch64) arch_tag="aarch64" ;;
        *)
          print_error "Amazon Corretto 暂不支持的架构: $arch"
          exit 1
          ;;
      esac
      echo "https://corretto.aws/downloads/latest/amazon-corretto-${feature}-${arch_tag}-${os}-${type}.tar.gz"
      ;;
    openjdk)
      # 使用 OpenJDK 官方 GA 17「latest」链接（仅 JDK）
      # 示例:
      #   https://download.java.net/java/GA/jdk17/latest/binaries/openjdk-17_linux-x64_bin.tar.gz
      if [[ "$type" != "jdk" ]]; then
        print_error "OpenJDK 官方构建当前仅提供 JDK，本脚本不支持 OpenJDK JRE 单独安装。"
        exit 1
      fi
      local os_tag arch_tag
      os_tag="$os"
      case "$arch" in
        x64) arch_tag="x64" ;;
        aarch64) arch_tag="aarch64" ;;
        *)
          print_error "OpenJDK 暂不支持的架构: $arch"
          exit 1
          ;;
      esac
      echo "https://download.java.net/java/GA/jdk${feature}/latest/binaries/openjdk-${feature}_${os_tag}-${arch_tag}_bin.tar.gz"
      ;;
    graalvm)
      # GraalVM Community 构建托管在 GitHub，使用 API 获取最新 release 的 asset URL
      # 仅支持 JDK
      if [[ "$type" != "jdk" ]]; then
        print_error "GraalVM 仅提供 JDK 镜像，请选择 JDK。"
        exit 1
      fi

      local api_url="https://api.github.com/repos/graalvm/graalvm-ce-builds/releases/latest"
      print_info "从 GitHub API 获取 GraalVM 最新版本信息..."

      # 根据架构选择匹配关键字
      local arch_tag
      case "$arch" in
        x64) arch_tag="linux-x64" ;;
        aarch64) arch_tag="linux-aarch64" ;;
        *)
          print_error "GraalVM 暂不支持的架构: $arch"
          exit 1
          ;;
      esac

      local url
      # 从 JSON 中简单 grep 匹配 tar.gz 下载地址，避免依赖 jq
      url="$(wget -qO- "$api_url" | grep -o "https://github.com/graalvm/graalvm-ce-builds/releases/download/[^\"]*${arch_tag}\.tar\.gz" | head -n 1 || true)"

      if [[ -z "$url" ]]; then
        print_error "未能从 GitHub 获取 GraalVM 下载地址，请稍后重试。"
        exit 1
      fi
      echo "$url"
      ;;
    *)
      print_error "未知发行版: $vendor"
      exit 1
      ;;
  esac
}

# ---------------------- 下载与解压 ----------------------

download_java() {
  local url="$1"
  local dest_dir="$2"

  mkdir -p "$dest_dir"
  local filename
  filename="$(basename "${url%%\?*}")"
  local filepath="${dest_dir}/${filename}"

  print_subsection "下载 Java 包"
  print_info "下载地址: $url"
  print_info "保存到 : $filepath"
  echo

  # 使用 wget 显示下载进度，并在失败时输出详细原因
  # -S         : 显示服务器响应头（便于排查 HTTP 状态码等问题）
  # --progress : 强制使用进度条显示
  # stderr 重定向到临时日志文件，失败时一起打印出来
  local wget_log="${dest_dir}/wget_java.log"
  if ! wget -S --progress=bar:force -O "$filepath" "$url" 2>"$wget_log"; then
    print_error "下载失败，请检查网络连接或发行版服务器。"
    if [[ -s "$wget_log" ]]; then
      echo
      print_info "wget 失败详细信息如下（便于排查原因）:"
      # 给错误日志每行加上前缀缩进，避免与正常输出混淆
      sed 's/^/  /' "$wget_log" >&2 || true
    fi
    exit 1
  fi

  print_success "下载完成"
  echo "$filepath"
}

extract_java() {
  local tarball="$1"
  local install_root="$2"
  local vendor="$3"

  mkdir -p "$install_root/$vendor"

  print_subsection "解压安装"
  print_info "解压到: $install_root/$vendor"

  tar -xzf "$tarball" -C "$install_root/$vendor"

  # 通过 tar 内容获得顶层目录名
  local top_dir
  top_dir="$(tar -tf "$tarball" | head -n 1 | cut -d/ -f1)"

  if [[ -z "$top_dir" ]]; then
    print_error "无法确定解压后的目录名。"
    exit 1
  fi

  local java_home="$install_root/$vendor/$top_dir"

  if [[ ! -d "$java_home" ]]; then
    print_warning "预期目录不存在: $java_home，尝试自动探测。"
    java_home="$(find "$install_root/$vendor" -maxdepth 2 -type d -name 'jdk*' -o -name 'graalvm*' | head -n 1 || true)"
  fi

  if [[ -z "$java_home" || ! -d "$java_home" ]]; then
    print_error "未能找到有效的 JAVA_HOME 目录。"
    exit 1
  fi

  print_success "解压完成，JAVA_HOME: $java_home"
  echo "$java_home"
}

# ---------------------- 写入环境变量 ----------------------

write_profile_java() {
  local java_home="$1"
  local vendor="$2"
  local profile_file="/etc/profile.d/java.sh"

  print_subsection "写入环境变量到 $profile_file"

  cat > "$profile_file" <<EOF
#!/usr/bin/env bash
#
# 自动生成: Java 环境变量

export JAVA_VENDOR="$vendor"
export JAVA_HOME="$java_home"
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF

  chmod 644 "$profile_file"

  print_success "已写入 JAVA_HOME 和 PATH 设置到: $profile_file"
  print_info "对新登录的 Shell 生效，当前会话可手动执行: source $profile_file"
}

# ---------------------- Maven 安装相关 ----------------------

prompt_install_maven() {
  local choice

  if [[ -n "$INSTALL_MAVEN" ]]; then
    case "${INSTALL_MAVEN,,}" in
      y|yes)
        print_info "使用环境变量 INSTALL_MAVEN=yes，将安装 Maven。"
        INSTALL_MAVEN="y"
        return 0
        ;;
      n|no)
        print_info "使用环境变量 INSTALL_MAVEN=no，将跳过 Maven 安装。"
        INSTALL_MAVEN="n"
        return 0
        ;;
      *)
        print_warning "无效的 INSTALL_MAVEN=${INSTALL_MAVEN}，将进入交互式选择。"
        ;;
    esac
  fi

  echo
  echo "是否安装 Apache Maven（构建 Java 项目常用工具）?"
  echo "  1) 是，安装最新稳定版 Maven"
  echo "  2) 否，跳过 Maven 安装"
  echo

  while true; do
    read -rp "请输入选项 [1/2] (默认 2 跳过): " choice
    case "${choice,,}" in
      1)
        INSTALL_MAVEN="y"
        break
        ;;
      2|"")
        INSTALL_MAVEN="n"
        break
        ;;
      *)
        print_warning "无效输入，请输入 1 或 2。"
        ;;
    esac
  done
}

detect_latest_maven_version() {
  local base_url="https://dlcdn.apache.org/maven/maven-3/"

  print_info "从 Apache 镜像获取 Maven 最新版本信息..."

  # 从目录列表中提取 3.x.y 形式的版本号，使用 sort -V 选择最大版本
  local latest
  latest="$(wget -qO- "$base_url" \
    | grep -Eo 'href=\"3\.[0-9]+\.[0-9]+/' \
    | sed -E 's/href=\"(3\.[0-9]+\.[0-9]+)\/\"/\1/' \
    | sort -V \
    | tail -n 1 || true)"

  if [[ -z "$latest" ]]; then
    print_error "未能获取 Maven 最新版本号，请稍后重试。"
    exit 1
  fi

  echo "$latest"
}

download_maven() {
  local version="$1"

  mkdir -p "$MAVEN_TMP_DIR"

  local base_url="https://dlcdn.apache.org/maven/maven-3"
  local url="${base_url}/${version}/binaries/apache-maven-${version}-bin.tar.gz"
  local tarball="${MAVEN_TMP_DIR}/apache-maven-${version}-bin.tar.gz"

  print_subsection "下载 Maven"
  print_info "Maven 版本: $version"
  print_info "下载地址  : $url"
  print_info "保存到    : $tarball"
  echo

  local wget_log="${MAVEN_TMP_DIR}/wget_maven.log"
  if ! wget -S --progress=bar:force -O "$tarball" "$url" 2>"$wget_log"; then
    print_error "Maven 下载失败，请检查网络连接或镜像站点。"
    if [[ -s "$wget_log" ]]; then
      echo
      print_info "wget 失败详细信息如下（便于排查原因）:"
      sed 's/^/  /' "$wget_log" >&2 || true
    fi
    exit 1
  fi

  print_success "Maven 下载完成"
  echo "$tarball"
}

extract_maven() {
  local tarball="$1"

  mkdir -p "$MAVEN_INSTALL_ROOT"

  print_subsection "解压 Maven"
  print_info "解压到: $MAVEN_INSTALL_ROOT"

  tar -xzf "$tarball" -C "$MAVEN_INSTALL_ROOT"

  local top_dir
  top_dir="$(tar -tf "$tarball" | head -n 1 | cut -d/ -f1)"

  if [[ -z "$top_dir" ]]; then
    print_error "无法确定 Maven 解压后的目录名。"
    exit 1
  fi

  local maven_home="${MAVEN_INSTALL_ROOT}/${top_dir}"

  if [[ ! -d "$maven_home" ]]; then
    print_error "未能找到有效的 Maven 安装目录: $maven_home"
    exit 1
  fi

  print_success "Maven 解压完成，MAVEN_HOME: $maven_home"
  echo "$maven_home"
}

write_profile_maven() {
  local maven_home="$1"
  local profile_file="/etc/profile.d/maven.sh"

  print_subsection "写入 Maven 环境变量到 $profile_file"

  cat > "$profile_file" <<EOF
#!/usr/bin/env bash
#
# 自动生成: Maven 环境变量

export M2_HOME="$maven_home"
export MAVEN_HOME="\$M2_HOME"
export PATH="\$M2_HOME/bin:\$PATH"
EOF

  chmod 644 "$profile_file"

  print_success "已写入 M2_HOME / MAVEN_HOME 和 PATH 设置到: $profile_file"
  print_info "对新登录的 Shell 生效，当前会话可手动执行: source $profile_file"
}

# ---------------------- Web 服务器安装相关 ----------------------

prompt_install_web_server() {
  local choice input_path

  if [[ -n "$INSTALL_WEB_SERVER" ]]; then
    case "${INSTALL_WEB_SERVER,,}" in
      y|yes)
        print_info "使用环境变量 INSTALL_WEB_SERVER=yes，将安装 Web 服务器。"
        INSTALL_WEB_SERVER="y"
        ;;
      n|no)
        print_info "使用环境变量 INSTALL_WEB_SERVER=no，将跳过 Web 服务器安装。"
        INSTALL_WEB_SERVER="n"
        return 0
        ;;
      *)
        print_warning "无效的 INSTALL_WEB_SERVER=${INSTALL_WEB_SERVER}，将进入交互式选择。"
        ;;
    esac
  fi

  if [[ -z "$INSTALL_WEB_SERVER" ]]; then
    echo
    echo "是否安装 Web 服务器?"
    echo "  1) 是"
    echo "  2) 否 (默认)"
    echo

    while true; do
      read -rp "请输入选项 [1/2] (默认 2 跳过): " choice
      case "${choice,,}" in
        1)
          INSTALL_WEB_SERVER="y"
          break
          ;;
        2|"")
          INSTALL_WEB_SERVER="n"
          return 0
          ;;
        *)
          print_warning "无效输入，请输入 1 或 2。"
          ;;
      esac
    done
  fi

  # 选择具体 Web 服务器
  if [[ -n "$WEB_SERVER_CHOICE" ]]; then
    case "${WEB_SERVER_CHOICE,,}" in
      tomcat|jetty|undertow)
        WEB_SERVER_CHOICE="${WEB_SERVER_CHOICE,,}"
        print_info "使用环境变量 WEB_SERVER_CHOICE: $WEB_SERVER_CHOICE"
        ;;
      *)
        print_warning "无效的 WEB_SERVER_CHOICE=${WEB_SERVER_CHOICE}，将进入交互式选择。"
        WEB_SERVER_CHOICE=""
        ;;
    esac
  fi

  if [[ -z "$WEB_SERVER_CHOICE" ]]; then
    echo
    echo "请选择要安装的 Web 服务器:"
    echo "  1) Tomcat   (默认)"
    echo "  2) Jetty"
    echo "  3) Undertow"
    echo

    while true; do
      read -rp "请输入选项 [1/2/3] (默认 1): " choice
      case "${choice,,}" in
        1|"")
          WEB_SERVER_CHOICE="tomcat"
          break
          ;;
        2)
          WEB_SERVER_CHOICE="jetty"
          break
          ;;
        3)
          WEB_SERVER_CHOICE="undertow"
          break
          ;;
        *)
          print_warning "无效输入，请输入 1 / 2 / 3。"
          ;;
      esac
    done
  fi

  # 输入安装路径
  if [[ -n "$WEB_SERVER_INSTALL_PATH" ]]; then
    print_info "使用 Web 服务器安装路径: $WEB_SERVER_INSTALL_PATH"
  else
    read -rp "请输入 Web 服务器安装路径 (默认 /opt/webserver): " input_path
    WEB_SERVER_INSTALL_PATH="${input_path:-/opt/webserver}"
  fi
}

download_web_server() {
  local server="$1"

  mkdir -p "$WEB_TMP_DIR"

  local url tarball

  case "$server" in
    tomcat)
      # 固定一个较新的稳定版本，后续如需更新可直接修改此处
      tarball="apache-tomcat-10.1.31.tar.gz"
      url="https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.31/bin/${tarball}"
      ;;
    jetty)
      # 使用 Jetty 11 的发行版 tar 包
      tarball="jetty-distribution-11.0.24.tar.gz"
      url="https://repo1.maven.org/maven2/org/eclipse/jetty/jetty-distribution/11.0.24/${tarball}"
      ;;
    undertow)
      # Undertow 以可执行 JAR 形式提供，这里下载一个可直接 java -jar 运行的版本
      tarball="undertow-servlet-2.2.17.Final.jar"
      url="https://repo1.maven.org/maven2/io/undertow/undertow-servlet/2.2.17.Final/${tarball}"
      ;;
    *)
      print_error "未知的 Web 服务器类型: $server"
      exit 1
      ;;
  esac

  local dest="${WEB_TMP_DIR}/${tarball}"

  print_subsection "下载 Web 服务器 ($server)"
  print_info "下载地址: $url"
  print_info "保存到  : $dest"

  local wget_log="${WEB_TMP_DIR}/wget_web_${server}.log"
  if ! wget -S --progress=bar:force -O "$dest" "$url" 2>"$wget_log"; then
    print_error "$server 下载失败，请检查网络连接或镜像站点。"
    if [[ -s "$wget_log" ]]; then
      echo
      print_info "wget 失败详细信息如下（便于排查原因）:"
      sed 's/^/  /' "$wget_log" >&2 || true
    fi
    exit 1
  fi

  print_success "$server 下载完成"
  echo "$dest"
}

install_web_server() {
  local server="$1"
  local archive_path

  archive_path="$(download_web_server "$server")"

  mkdir -p "$WEB_SERVER_INSTALL_PATH"

  local server_home=""

  case "$server" in
    tomcat|jetty)
      print_subsection "解压 $server 到 $WEB_SERVER_INSTALL_PATH"
      tar -xzf "$archive_path" -C "$WEB_SERVER_INSTALL_PATH"

      local top_dir
      top_dir="$(tar -tf "$archive_path" | head -n 1 | cut -d/ -f1)"

      if [[ -z "$top_dir" ]]; then
        print_error "无法确定 $server 解压后的目录名。"
        exit 1
      fi

      server_home="${WEB_SERVER_INSTALL_PATH}/${top_dir}"

      if [[ ! -d "$server_home" ]]; then
        print_error "未能找到有效的 $server 安装目录: $server_home"
        exit 1
      fi
      ;;
    undertow)
      print_subsection "安装 Undertow"
      server_home="${WEB_SERVER_INSTALL_PATH}/undertow-servlet-2.2.17.Final"
      mkdir -p "$server_home"
      cp "$archive_path" "${server_home}/undertow-servlet-2.2.17.Final.jar"
      ;;
  esac

  # 写入环境变量
  case "$server" in
    tomcat)
      local profile_file="/etc/profile.d/tomcat.sh"
      print_subsection "写入 Tomcat 环境变量到 $profile_file"
      cat > "$profile_file" <<EOF
#!/usr/bin/env bash
#
# 自动生成: Tomcat 环境变量

export CATALINA_HOME="$server_home"
export PATH="\$CATALINA_HOME/bin:\$PATH"
EOF
      chmod 644 "$profile_file"
      ;;
    jetty)
      local profile_file="/etc/profile.d/jetty.sh"
      print_subsection "写入 Jetty 环境变量到 $profile_file"
      cat > "$profile_file" <<EOF
#!/usr/bin/env bash
#
# 自动生成: Jetty 环境变量

export JETTY_HOME="$server_home"
export PATH="\$JETTY_HOME/bin:\$PATH"
EOF
      chmod 644 "$profile_file"
      ;;
    undertow)
      local profile_file="/etc/profile.d/undertow.sh"
      print_subsection "写入 Undertow 环境变量到 $profile_file"
      cat > "$profile_file" <<EOF
#!/usr/bin/env bash
#
# 自动生成: Undertow 环境变量

export UNDERTOW_HOME="$server_home"
EOF
      chmod 644 "$profile_file"
      ;;
  esac

  print_success "$server 环境变量配置完成"
  echo "$server_home"
}

verify_web_server() {
  local server="$1"
  local server_home="$2"

  print_subsection "验证 $server 安装和运行情况"

  local status=0

  case "$server" in
    tomcat)
      if [[ ! -x "$server_home/bin/startup.sh" ]]; then
        print_error "未找到 Tomcat 启动脚本: $server_home/bin/startup.sh"
        return 1
      fi
      if [[ ! -x "$server_home/bin/shutdown.sh" ]]; then
        print_error "未找到 Tomcat 关闭脚本: $server_home/bin/shutdown.sh"
        return 1
      fi

      if ! "$server_home/bin/startup.sh"; then
        print_error "Tomcat 启动失败。"
        return 1
      fi

      sleep 5

      if ! "$server_home/bin/shutdown.sh"; then
        print_error "Tomcat 关闭失败。"
        return 1
      fi
      ;;
    jetty)
      if [[ ! -x "$server_home/bin/jetty.sh" ]]; then
        print_error "未找到 Jetty 启动脚本: $server_home/bin/jetty.sh"
        return 1
      fi

      if ! "$server_home/bin/jetty.sh" start; then
        print_error "Jetty 启动失败。"
        return 1
      fi

      sleep 5

      if ! "$server_home/bin/jetty.sh" stop; then
        print_error "Jetty 关闭失败。"
        return 1
      fi
      ;;
    undertow)
      local jar_path="${server_home}/undertow-servlet-2.2.17.Final.jar"
      if [[ ! -f "$jar_path" ]]; then
        print_error "未找到 Undertow 可执行 JAR: $jar_path"
        return 1
      fi

      # 在后台启动 Undertow，并在短暂等待后尝试关闭
      java -jar "$jar_path" >/dev/null 2>&1 &
      local pid=$!
      sleep 5

      if ! kill "$pid" >/dev/null 2>&1; then
        print_error "无法正常关闭 Undertow (PID $pid)。"
        return 1
      fi
      ;;
    *)
      print_error "未知的 Web 服务器类型: $server"
      return 1
      ;;
  esac

  print_success "$server 启动和关闭验证成功。"
  return "$status"
}

# ---------------------- 主流程 ----------------------

print_section "1/3 选择 Java 发行版与类型"

prompt_vendor
prompt_type
prompt_feature

print_success "选择发行版: $JAVA_VENDOR"
print_success "选择类型  : $JAVA_TYPE"
print_success "目标版本  : $JAVA_FEATURE (可通过 JAVA_FEATURE 环境变量预设)"

print_section "2/3 下载并安装 Java"

mkdir -p "$TMP_DIR"

DOWNLOAD_URL="$(build_download_url "$JAVA_VENDOR" "$JAVA_TYPE" "$JAVA_FEATURE" "$OS" "$ARCH")"
TARBALL_PATH="$(download_java "$DOWNLOAD_URL" "$TMP_DIR")"

JAVA_HOME_VALUE="$(extract_java "$TARBALL_PATH" "$INSTALL_ROOT" "$JAVA_VENDOR")"

print_section "3/3 配置环境变量"

write_profile_java "$JAVA_HOME_VALUE" "$JAVA_VENDOR"

# 可选：安装 Maven
MAVEN_HOME_VALUE=""
prompt_install_maven

if [[ "$INSTALL_MAVEN" == "y" ]]; then
  print_section "附加操作: 安装 Maven"

  local maven_version maven_tarball
  maven_version="$(detect_latest_maven_version)"
  maven_tarball="$(download_maven "$maven_version")"
  MAVEN_HOME_VALUE="$(extract_maven "$maven_tarball")"
  write_profile_maven "$MAVEN_HOME_VALUE"
else
  print_info "已选择跳过 Maven 安装。"
fi

# 可选：安装 Web 服务器
WEB_SERVER_HOME_VALUE=""
WEB_SERVER_SELECTED=""

prompt_install_web_server

if [[ "$INSTALL_WEB_SERVER" == "y" ]]; then
  print_section "附加操作: 安装 Web 服务器 ($WEB_SERVER_CHOICE)"

  WEB_SERVER_SELECTED="$WEB_SERVER_CHOICE"
  WEB_SERVER_HOME_VALUE="$(install_web_server "$WEB_SERVER_SELECTED")"

  if ! verify_web_server "$WEB_SERVER_SELECTED" "$WEB_SERVER_HOME_VALUE"; then
    print_error "Web 服务器 $WEB_SERVER_SELECTED 安装或配置验证失败，请检查日志和配置。"
  else
    print_success "Web 服务器 $WEB_SERVER_SELECTED 安装和配置验证成功。"
  fi
else
  print_info "已选择跳过 Web 服务器安装。"
fi

echo
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│                     Java 安装完成                           │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "发行版" "$JAVA_VENDOR"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "镜像类型" "$JAVA_TYPE"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "JAVA_HOME" "$JAVA_HOME_VALUE"
printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "java 路径" "$JAVA_HOME_VALUE/bin/java"
if [[ -n "$MAVEN_HOME_VALUE" ]]; then
  printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "MAVEN_HOME" "$MAVEN_HOME_VALUE"
  printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "mvn 路径" "$MAVEN_HOME_VALUE/bin/mvn"
fi
if [[ -n "$WEB_SERVER_HOME_VALUE" ]]; then
  printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "Web 服务器" "$WEB_SERVER_SELECTED"
  printf "${CYAN}│${NC}  %-20s: %-37s ${CYAN}│${NC}\n" "Web 目录" "$WEB_SERVER_HOME_VALUE"
fi
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│${NC}  请重新登录终端，或执行: ${GREEN}source /etc/profile.d/java.sh${NC}      ${CYAN}│${NC}"
if [[ -n "$MAVEN_HOME_VALUE" ]]; then
echo -e "${CYAN}│${NC}  并执行: ${GREEN}source /etc/profile.d/maven.sh${NC}                          ${CYAN}│${NC}"
fi
if [[ -n "$WEB_SERVER_HOME_VALUE" ]]; then
  case "$WEB_SERVER_SELECTED" in
    tomcat)
      echo -e "${CYAN}│${NC}  并执行: ${GREEN}source /etc/profile.d/tomcat.sh${NC}                         ${CYAN}│${NC}"
      ;;
    jetty)
      echo -e "${CYAN}│${NC}  并执行: ${GREEN}source /etc/profile.d/jetty.sh${NC}                          ${CYAN}│${NC}"
      ;;
    undertow)
      echo -e "${CYAN}│${NC}  并执行: ${GREEN}source /etc/profile.d/undertow.sh${NC}                       ${CYAN}│${NC}"
      ;;
  esac
fi
echo -e "${CYAN}│${NC}  验证 Java: ${GREEN}java -version${NC}                                  ${CYAN}│${NC}"
if [[ -n "$MAVEN_HOME_VALUE" ]]; then
echo -e "${CYAN}│${NC}  验证 Maven: ${GREEN}mvn -v${NC}                                       ${CYAN}│${NC}"
fi
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo
