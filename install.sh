#!/bin/bash

# ============================================================
# Hysteria v2 一键交互式安装脚本
# ============================================================
# 功能：
#   1) 前置环境检测（OS / 架构 / systemd / 依赖 / 公网 IP / 端口占用）
#   2) 交互式参数询问（端口 / 密码 / 端口跳跃 / 证书 / 伪装地址）
#   3) 支持两种证书模式：自签证书 & 内置 ACME 真实证书（Cloudflare DNS + API Token，cfut_ 开头）
#   4) 端口跳跃：使用 Hysteria2 内置 listen: :起始-结束 范围，
#                HY2 自动通过 nftables / iptables 重定向其余端口到首个端口
#                服务停止时自动清理规则
#   5) 启动失败自动诊断 218/CAPABILITIES（systemd 太旧）并修复
#   6) 安装完成后交付：客户端 config.yaml / hysteria2:// 分享链接 / Clash.Meta 片段
# ============================================================

set +e

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- 提示函数 ---
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
step()    { echo ""; echo -e "${CYAN}==================== $1 ====================${NC}"; }
separator() { echo ""; echo -e "--------------------------------------------------"; echo ""; }

# --- URL Encode（用于生成分享链接）---
urlencode() {
    local s="$1" out="" i c o
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9_.~-]) out+="$c" ;;
            *) printf -v o '%%%02X' "'$c"; out+="$o" ;;
        esac
    done
    echo "$out"
}

# --- 统一解析 Y/N/yes/no 输入（大小写完全兼容）---
parse_yesno() {
    local v="${1,,}"
    local d="${2,,}"
    if [[ -z "$v" ]]; then
        [[ "$d" == "y" ]] && return 0 || return 1
    fi
    case "$v" in
        y|yes) return 0 ;;
        n|no)  return 1 ;;
        *)     [[ "$d" == "y" ]] && return 0 || return 1 ;;
    esac
}

# --- 输入清洗：去除首尾空白 + 首尾反引号（`）---
#   防止用户从提示示例中把 `...` 的反引号也复制进去
sanitize_input() {
    local v="$1"
    # 去首尾空白
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    # 去首尾反引号，循环直到首尾都不是
    while [[ "${v:0:1}" == "\`" ]]; do v="${v:1}"; done
    while [[ -n "$v" && "${v: -1}" == "\`" ]]; do v="${v:0:${#v}-1}"; done
    # 再去一次首尾空白，防止去反引号后又露出空格
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    echo -n "$v"
}

# ============================================================
# 欢迎界面 & 权限检查
# ============================================================
clear
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Hysteria v2 一键交互式安装脚本          ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════╝${NC}"
echo ""
info "本脚本将引导你完成 Hysteria v2 服务端的安装和配置"
warn "请确保以 root 或 sudo 权限运行此脚本"
echo ""

# --- 检查 root 权限 ---
if [[ $EUID -ne 0 ]]; then
    error "此脚本需要 root 权限运行，请使用 sudo 执行"
    exit 1
fi
success "权限检查通过"
separator

# ============================================================
# 环境检测
# ============================================================
step "环境检测：Hysteria v2 运行条件检查"

ENV_CHECK_PASS=true
SERVER_IP="你的服务器IP"

# [1/8] 操作系统
info "[1/8] 检查操作系统类型 ..."
OS=$(uname -s 2>/dev/null)
OS_DETAIL="$(cat /etc/os-release 2>/dev/null | grep -E '^PRETTY_NAME=' | cut -d= -f2 | tr -d '\"' || uname -sr)"
if [[ "$OS" != "Linux" ]]; then
    error "检测到操作系统: $OS $OS_DETAIL"
    error "Hysteria v2 一键脚本目前只支持 Linux 服务器"
    ENV_CHECK_PASS=false
else
    success "操作系统: Linux ${OS_DETAIL}"
fi

# [2/8] CPU 架构
echo ""
info "[2/8] 检查 CPU 架构 ..."
ARCH=$(uname -m 2>/dev/null)
case "$ARCH" in
    x86_64|amd64)  ARCH_ALIAS="amd64"; success "架构: ${ARCH_ALIAS} (${ARCH})" ;;
    aarch64|arm64) ARCH_ALIAS="arm64"; success "架构: ${ARCH_ALIAS} (${ARCH})" ;;
    armv7l)        ARCH_ALIAS="arm";   success "架构: ${ARCH_ALIAS} (${ARCH})" ;;
    *)             warn "架构: ${ARCH}（官方可能无对应二进制，尝试强行安装）"; ENV_CHECK_PASS=false ;;
esac

# [3/8] systemd 检查
echo ""
info "[3/8] 检查 systemd ..."
if command -v systemctl >/dev/null 2>&1; then
    SYSTEMD_VER=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')
    if [[ "$SYSTEMD_VER" =~ ^[0-9]+$ ]] && (( SYSTEMD_VER >= 229 )); then
        success "systemd 版本: v${SYSTEMD_VER}（完美兼容）"
    else
        if [[ -n "$SYSTEMD_VER" ]]; then
            warn "systemd 版本过低 (v${SYSTEMD_VER} < v229)：官方 service 文件中的 AmbientCapabilities= 将触发 218/CAPABILITIES 错误"
            warn "        → 脚本将在服务启动失败时自动尝试修复"
        else
            warn "无法读取 systemd 版本，将假设为低版本处理"
        fi
    fi
else
    error "未检测到 systemctl，本脚本依赖 systemd 管理服务"
    ENV_CHECK_PASS=false
fi

# [4/8] 必要命令
echo ""
info "[4/8] 检查必要命令 (curl / openssl) ..."
MISSING_CMD=""
for c in curl openssl; do
    if command -v "$c" >/dev/null 2>&1; then
        printf "       ${GREEN}✓${NC} %s 已安装" "$c"
    else
        printf "       ${RED}✗${NC} %s 未安装" "$c"
        MISSING_CMD="$MISSING_CMD $c"
        ENV_CHECK_PASS=false
    fi
done
for c in ss netstat; do
    if command -v "$c" >/dev/null 2>&1; then
        printf "   ${GREEN}✓${NC} %s 已安装" "$c"
        break
    fi
done
echo ""
[[ -n "$MISSING_CMD" ]] && error "缺失命令: $MISSING_CMD，请先安装后重试（apt/yum 对应包: ca-certificates curl openssl）"

# [5/8] 公网 IP
echo ""
info "[5/8] 获取服务器公网 IP ..."
SERVER_IP=$(curl -s -4 --connect-timeout 8 icanhazip.com 2>/dev/null \
        || curl -s -4 --connect-timeout 8 ifconfig.me 2>/dev/null \
        || curl -s -4 --connect-timeout 8 ip.sb 2>/dev/null \
        || curl -s -4 --connect-timeout 8 https://api.ipify.org 2>/dev/null \
        || echo "")
if [[ -n "$SERVER_IP" && "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    success "公网 IPv4: ${SERVER_IP}"
else
    warn "无法自动获取公网 IP，安装完成后请手动替换配置中的「你的服务器IP」"
    SERVER_IP="你的服务器IP"
fi

# [6/8] 能否访问官方源
echo ""
info "[6/8] 检查能否访问 get.hy2.sh ..."
if curl -fsSL --connect-timeout 10 --max-time 15 https://get.hy2.sh/ >/dev/null 2>&1; then
    success "get.hy2.sh 可访问"
else
    warn "get.hy2.sh 访问超时（安装 Hysteria 时可能失败）"
    ENV_CHECK_PASS=false
fi

# [7/8] 旧安装痕迹
echo ""
info "[7/8] 检查旧安装痕迹 ..."
OLD_INSTALL=false
command -v hysteria >/dev/null 2>&1 \
    || [[ -f /etc/systemd/system/hysteria-server.service ]] \
    || [[ -f /lib/systemd/system/hysteria-server.service ]] \
    || [[ -d /etc/hysteria ]] && OLD_INSTALL=true
if $OLD_INSTALL; then
    warn "检测到已有 Hysteria v2 安装痕迹："
    command -v hysteria >/dev/null 2>&1 && echo "       · 已存在二进制: $(command -v hysteria)"
    [[ -f /etc/systemd/system/hysteria-server.service || -f /lib/systemd/system/hysteria-server.service ]] \
        && echo "       · 已存在 systemd 服务单元 hysteria-server.service"
    [[ -d /etc/hysteria ]] && echo "       · 已存在配置目录 /etc/hysteria/（旧配置将被自动备份为 .bak）"
    warn "        → 安装脚本会在生成配置前备份旧配置"
else
    success "未检测到旧安装，为全新安装"
fi

# [8/8] 综合
echo ""
info "[8/8] 综合判定 ..."
if $ENV_CHECK_PASS; then
    success "✅ 环境检查全部通过，可直接进行安装"
else
    warn "⚠️  环境检测存在以上问题，强行安装可能失败，是否仍继续？"
    read -p "继续安装？[y/n]: " FORCE
    if ! parse_yesno "$FORCE" "n"; then
        error "用户取消安装，脚本退出"
        exit 0
    fi
fi
separator

# ============================================================
# 第 1 步：配置参数设置
# ============================================================
step "第 1 步：配置参数设置"

DEFAULT_PORT=10000
DEFAULT_PASSWORD="123456789"
DEFAULT_MASK_URL="https://bing.com"

# ---- 主监听端口（带占用检测）----
while true; do
    read -p "请输入主监听端口 [默认: ${DEFAULT_PORT}]: " INPUT_PORT
    PORT=${INPUT_PORT:-$DEFAULT_PORT}
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT<1 || PORT>65535 )); then
        error "端口必须是 1-65535 的数字，请重新输入"
        continue
    fi
    PORT_IN_USE=false
    if command -v ss >/dev/null 2>&1; then
        ss -lntup 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$" && PORT_IN_USE=true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntup 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$" && PORT_IN_USE=true
    fi
    if $PORT_IN_USE; then
        warn "端口 ${PORT} 已被占用，请换一个端口"
        continue
    fi
    if (( PORT < 1024 )); then
        warn "端口 ${PORT} < 1024，需要 CAP_NET_BIND_SERVICE，低版本 systemd 可能不支持"
    fi
    break
done
info "主监听端口设置为: ${PORT}"
echo ""

# ---- 端口跳跃 ----
#   只使用 HY2 内置 listen: :a-b 端口范围（Linux 自带，会自动用 nft/iptables 重定向其余端口到 a，
#   且服务关闭时自动清理规则，无需手动维护 iptables）。
echo -e "${MAGENTA}[端口跳跃]${NC} 启用后客户端连接会在指定范围内随机切换端口，规避 QoS/封单端口"
echo "   · 使用 Hysteria2 内置 listen 端口范围：自动通过 nft/iptables 重定向"
echo "   · 服务停止时 HY2 自动清理防火墙规则，无需手动维护"
echo "   · 注意：需要 root / CAP_NET_ADMIN 权限，并系统装有 nft 或 iptables"
echo ""
read -p "启用端口跳跃？[y/n]: " INPUT_HOP
PORT_HOP=false
HOP_PORTS=""
HOP_START=""
HOP_END=""

if parse_yesno "$INPUT_HOP" "n"; then
    PORT_HOP=true
    echo ""
    info "跳跃端口范围格式要求：单段连续范围 a-b（例如 10000-20000）"
    echo "   · HY2 以「起始端口 a」作为主监听端口，主端口会自动从前面设置的端口改为 a"
    echo "   · 结束端口 b 必须大于 a，且 a-b 整体在 1-65535 之间"
    echo ""
    while true; do
        read -p "请输入跳跃端口范围（如 10000-20000）: " INPUT_HOP_PORTS
        INPUT_HOP_PORTS=$(sanitize_input "$INPUT_HOP_PORTS")
        if [[ -z "$INPUT_HOP_PORTS" ]]; then
            error "跳跃端口范围不能为空，请重新输入"
            continue
        fi
        if [[ "$INPUT_HOP_PORTS" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            HOP_START="${BASH_REMATCH[1]}"
            HOP_END="${BASH_REMATCH[2]}"
            if (( HOP_START >= HOP_END )); then
                error "范围起始端口(${HOP_START})必须小于结束端口(${HOP_END})，请重新输入"
                continue
            fi
            if (( HOP_END > 65535 || HOP_START < 1 )); then
                error "端口范围必须在 1-65535 内"
                continue
            fi
            HOP_PORTS="${HOP_START}-${HOP_END}"
            # HY2 内置 listen: :a-b 会把第一个端口 a 当做主端口，对齐前面设置的 PORT
            if [[ "$PORT" != "$HOP_START" ]]; then
                warn "HY2 内置 listen: :${HOP_START}-${HOP_END} 会以 ${HOP_START} 作为主端口"
                info "已自动将主监听端口从 ${PORT} → ${HOP_START}"
                PORT=$HOP_START
            fi
            break
        else
            error "端口范围必须形如 a-b（例如 10000-20000），请重新输入"
            continue
        fi
    done

    success "端口跳跃已启用: HY2 内置 listen: :${HOP_START}-${HOP_END}（自动维护 nft/iptables）"
else
    info "端口跳跃未启用"
fi
echo ""

# ---- 连接密码 ----
while true; do
    read -p "请输入连接密码 [默认: ${DEFAULT_PASSWORD}]: " INPUT_PWD
    INPUT_PWD=$(sanitize_input "$INPUT_PWD")
    PASSWORD=${INPUT_PWD:-$DEFAULT_PASSWORD}
    if [[ -n "$PASSWORD" ]]; then
        break
    fi
    error "密码不能为空，请重新输入"
done
info "连接密码设置为: ${PASSWORD}"
echo ""

# ========== SSL 证书类型 ==========
echo -e "${MAGENTA}[SSL证书]${NC} 选择证书类型："
echo "   1) 自签名证书（无需域名，客户端需 insecure=true）"
echo "   2) 真实 SSL 证书（Hysteria2 内置 ACME + Cloudflare DNS 自动申请/续期）"
echo ""
while true; do
    read -p "请选择 [1 或 2，默认: 1]: " INPUT_SSL_TYPE
    INPUT_SSL_TYPE=${INPUT_SSL_TYPE:-1}
    if [[ "$INPUT_SSL_TYPE" == "1" || "$INPUT_SSL_TYPE" == "2" ]]; then
        break
    fi
    error "输入无效，请输入 1 或 2"
done

SSL_MODE=$INPUT_SSL_TYPE
CERT_CN=""
REAL_DOMAIN=""
CF_TOKEN=""
CF_EMAIL=""
CLIENT_INSECURE=""
CLIENT_SNI=""

if [[ "$SSL_MODE" == "1" ]]; then
    # === 自签证书 ===
    DEFAULT_CERT_CN="bing.com"
    echo ""
    read -p "请输入自签证书的 SNI/CN 伪装域名 [默认: ${DEFAULT_CERT_CN}]: " INPUT_CN
    INPUT_CN=$(sanitize_input "$INPUT_CN")
    CERT_CN=${INPUT_CN:-$DEFAULT_CERT_CN}
    CLIENT_INSECURE="true"
    CLIENT_SNI=${CERT_CN}
    info "自签证书 CN/SNI 设置为: ${CERT_CN}"
else
    # === 真实 SSL 证书（Hysteria2 内置 ACME + Cloudflare DNS）===
    # 注意：HY2 用的 libdns/cloudflare 只支持「细粒度 API Token」，不支持旧版 Global API Key（Email+Key）。
    # 字段名必须写成：dns.config.cloudflare_api_token  （仅此一个，小写下划线）
    echo ""
    warn "真实证书模式需要："
    echo "   - 域名 DNS 托管在 Cloudflare，且 A 记录已指向本服务器 IP（建议灰色云朵仅 DNS）"
    echo "   - 凭证必须是 Cloudflare「API Token」（权限：Zone - Read + Zone - DNS - Edit，前缀通常是 cfut_）"
    echo "   - 证书由 Hysteria2 启动时自动申请并自动续期（内置 ACME 目录：/etc/hysteria/acme）"
    echo ""

    while true; do
        read -p "请输入用于 Hysteria 的完整域名（如 hy.example.com）: " INPUT_DOMAIN
        INPUT_DOMAIN=$(sanitize_input "$INPUT_DOMAIN")
        if [[ -n "$INPUT_DOMAIN" ]]; then
            REAL_DOMAIN=$INPUT_DOMAIN
            break
        fi
        error "域名不能为空"
    done
    CLIENT_SNI=${REAL_DOMAIN}
    CLIENT_INSECURE="false"
    success "域名为: ${REAL_DOMAIN}"
    echo ""

    # ACME 账户联系邮箱（Let's Encrypt 到期提醒会发到这儿，不参与 CF DNS 鉴权）
    read -p "请输入 ACME 账户联系邮箱（用于证书到期提醒，可留空）: " INPUT_ACME_EMAIL
    INPUT_ACME_EMAIL=$(sanitize_input "$INPUT_ACME_EMAIL")
    if [[ -n "$INPUT_ACME_EMAIL" ]]; then
        CF_EMAIL=$INPUT_ACME_EMAIL
        success "ACME 联系邮箱: ${CF_EMAIL}"
    else
        info "ACME 联系邮箱留空，将使用默认占位邮箱"
    fi
    echo ""

    # 唯一凭证字段：Cloudflare API Token（cfut_ 开头）
    while true; do
        read -p "请输入 Cloudflare API Token（Zone:Read + Zone.DNS:Edit 权限）: " INPUT_TOKEN
        INPUT_TOKEN=$(sanitize_input "$INPUT_TOKEN")
        if [[ -n "$INPUT_TOKEN" ]]; then
            CF_TOKEN=$INPUT_TOKEN
            break
        fi
        error "Token 不能为空"
    done
    success "CF API Token 已保存 (${CF_TOKEN:0:4}****${CF_TOKEN: -4})"
    echo ""
fi

# ========== 伪装地址 ==========
echo ""
read -p "请输入伪装网站地址 [默认: ${DEFAULT_MASK_URL}]: " INPUT_MASK
INPUT_MASK=$(sanitize_input "$INPUT_MASK")
MASK_URL=${INPUT_MASK:-$DEFAULT_MASK_URL}
info "伪装地址设置为: ${MASK_URL}"
echo ""

# ========== 配置确认 ==========
warn "═════════════ 请确认以下配置信息 ═════════════"
if [[ "$PORT_HOP" == "true" ]]; then
    echo "   listen 写法:    :${HOP_START}-${HOP_END}（HY2 内置端口范围，主端口=${PORT}）"
    echo "   端口跳跃:      已启用（HY2 内置 listen 范围，自动 nft/iptables）"
else
    echo "   主监听端口:    ${PORT}"
    echo "   端口跳跃:      未启用"
fi
echo "   连接密码:      ${PASSWORD}"
if [[ "$SSL_MODE" == "1" ]]; then
    echo "   证书类型:      自签名证书"
    echo "   证书 CN/SNI:   ${CERT_CN}"
else
    echo "   证书类型:      真实 SSL 证书 (内置 ACME + Cloudflare DNS)"
    echo "   证书域名:      ${REAL_DOMAIN}"
    echo "   ACME 邮箱:     ${CF_EMAIL:-（未填，使用占位）}"
    echo "   CF 凭证:       API Token: ${CF_TOKEN:0:4}****${CF_TOKEN: -4}"
fi
echo "   伪装地址:      ${MASK_URL}"
warn "═══════════════════════════════════════════════"
echo ""
read -p "确认以上配置无误，开始安装？[y/n]: " CONFIRM

if ! parse_yesno "$CONFIRM" "y"; then
    error "用户取消安装，脚本退出"
    exit 0
fi
success "配置已确认，开始安装..."
separator

# ============================================================
# 第 2 步：安装 Hysteria v2
# ============================================================
step "第 2 步：安装 Hysteria v2"
info "正在从官方下载并安装 Hysteria v2 ..."
if bash <(curl -fsSL https://get.hy2.sh/); then
    success "Hysteria v2 安装成功"
    if command -v hysteria >/dev/null 2>&1; then
        info "版本: $(hysteria version 2>/dev/null | head -1 || hysteria --version 2>/dev/null | head -1)"
    fi
else
    error "Hysteria v2 安装失败，请检查网络连接"
    exit 1
fi
separator

# ============================================================
# 第 3 步：证书目录 / 自签证书
# ============================================================
step "第 3 步：准备 TLS / 证书目录"

CERT_DIR="/etc/hysteria"
mkdir -p ${CERT_DIR}

if [[ "$SSL_MODE" == "1" ]]; then
    info "正在生成 ECC 自签名证书 (prime256v1)，有效期约 100 年 ..."
    info "证书 CN 为: ${CERT_CN}"

    if openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout ${CERT_DIR}/server.key \
      -out ${CERT_DIR}/server.crt \
      -subj "/CN=${CERT_CN}" -days 36500 2>/dev/null; then
        success "自签名 TLS 证书创建成功"
    else
        error "自签名 TLS 证书创建失败"
        exit 1
    fi
else
    info "使用 Hysteria2 内置 ACME，准备 ACME 存储目录：${CERT_DIR}/acme"
    mkdir -p ${CERT_DIR}/acme
    success "ACME 存储目录创建完成，Hysteria2 启动后会自动申请证书并续期"
fi

info "正在设置目录权限（chown -R hysteria:hysteria /etc/hysteria）..."
chown -R hysteria:hysteria ${CERT_DIR} 2>/dev/null
if [[ "$SSL_MODE" == "1" ]]; then
    chmod 600 ${CERT_DIR}/server.key 2>/dev/null
    chmod 644 ${CERT_DIR}/server.crt 2>/dev/null
fi
success "证书目录权限设置完成"
separator

# ============================================================
# 第 4 步：生成 /etc/hysteria/config.yaml
# ============================================================
step "第 4 步：生成配置文件"
info "正在备份旧配置并创建新配置文件 ..."

CONFIG_FILE="/etc/hysteria/config.yaml"
if [[ -f ${CONFIG_FILE} ]]; then
    info "检测到旧配置文件，正在备份为 config.yaml.bak ..."
    cp ${CONFIG_FILE} ${CONFIG_FILE}.bak
fi
rm -rf ${CONFIG_FILE}
touch ${CONFIG_FILE}

# ------- 证书 / ACME 段-------
# 模式 1 (自签) -> 顶级 tls: cert/key
# 模式 2 (真实) -> 顶级 acme: ...（与 listen/auth 平级，不再在 tls 下嵌套）
if [[ "$SSL_MODE" == "1" ]]; then
    TLS_OR_ACME_BLOCK="tls:
  cert: ${CERT_DIR}/server.crt
  key: ${CERT_DIR}/server.key"
else
    TLS_OR_ACME_BLOCK="acme:
  domains:
    - \"${REAL_DOMAIN}\"
  email: ${CF_EMAIL:-${CF_TOKEN:0:8}@hy.local}
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: ${CF_TOKEN}"
fi

# 决定 listen 写法：
#   - 不开跳跃：listen: :${PORT}
#   - 开端口跳跃：listen: :${HOP_START}-${HOP_END}
if [[ "$PORT_HOP" == "true" ]]; then
    LISTEN_LINE="listen: :${HOP_START}-${HOP_END}"
else
    LISTEN_LINE="listen: :${PORT}"
fi

cat > ${CONFIG_FILE} << EOF
${LISTEN_LINE}

${TLS_OR_ACME_BLOCK}

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASK_URL}
    rewriteHost: true

ignoreClientBandwidth: false
EOF

if [[ -f ${CONFIG_FILE} ]]; then
    success "配置文件写入成功: ${CONFIG_FILE}"
else
    error "配置文件写入失败"
    exit 1
fi

info "生成的配置文件内容："
echo ""
echo -e "${YELLOW}$(cat ${CONFIG_FILE})${NC}"
separator

# ============================================================
# 第 5 步：启用并启动 Hysteria 服务
#   - 包含 218/CAPABILITIES 自动修复
# ============================================================
step "第 5 步：启用并启动 Hysteria 服务"

info "正在设置开机自启 ..."
if systemctl enable hysteria-server 2>/dev/null; then
    success "已设置开机自启"
else
    warn "设置开机自启失败，请手动执行: systemctl enable hysteria-server"
fi

systemctl daemon-reload 2>/dev/null

if [[ "$SSL_MODE" == "2" ]]; then
    warn "首次启动时 Hysteria2 会通过 Cloudflare DNS 自动申请 ACME 证书，可能需要 1-3 分钟"
    warn "请耐心等待，不要中断服务..."
fi

# 如果启用了内置 listen 端口范围跳跃，提醒它会自动加 nft/iptables 规则（需要 CAP_NET_ADMIN）
if [[ "$PORT_HOP" == "true" ]]; then
    warn "内置 listen 端口范围模式下，Hysteria2 会自动调用 nftables/iptables 建立重定向规则"
    warn "  · 若 systemd service 以 hysteria 用户运行，脚本将在失败时自动赋予 CAP_NET_ADMIN 能力或兜底 root"
    warn "  · Hysteria2 正常关闭时会自动清理这些规则（硬 kill 除外）"
fi

info "正在启动服务 ..."
SVC_FILE="/etc/systemd/system/hysteria-server.service"
[[ ! -f "$SVC_FILE" ]] && SVC_FILE="/lib/systemd/system/hysteria-server.service"
[[ ! -f "$SVC_FILE" ]] && SVC_FILE="/usr/lib/systemd/system/hysteria-server.service"

START_OK=true
systemctl start hysteria-server 2>/dev/null || START_OK=false

if ! $START_OK; then
    EXIT_CODE=""
    EXIT_CODE=$(systemctl show hysteria-server -p ExecMainStatus --value 2>/dev/null || true)
    if [[ -z "$EXIT_CODE" ]]; then
        systemctl status hysteria-server 2>&1 | grep -q "status=218" && EXIT_CODE="218"
    fi

    info "启动退出码: ${EXIT_CODE:-(未知)}"

    if [[ "$EXIT_CODE" == "218" ]] || \
       systemctl status hysteria-server 2>&1 | grep -q "CAPABILITIES"; then
        warn "⚠️  检测到经典的 218/CAPABILITIES 错误（systemd 太旧不支持 AmbientCapabilities）"
        info "自动修复方案：注释掉 service 文件中的 AmbientCapabilities / CapabilityBoundingSet 字段"

        if [[ -f "$SVC_FILE" ]]; then
            info "正在修改: ${SVC_FILE}"
            sed -i 's/^AmbientCapabilities=/#AmbientCapabilities=/' "$SVC_FILE"
            sed -i 's/^CapabilityBoundingSet=/#CapabilityBoundingSet=/' "$SVC_FILE"
            # 监听 < 1024 需要 CAP_NET_BIND_SERVICE
            if (( PORT < 1024 )) && command -v setcap >/dev/null 2>&1 && [[ -x /usr/local/bin/hysteria ]]; then
                info "端口 < 1024，附加 setcap CAP_NET_BIND_SERVICE 处理 ..."
                setcap cap_net_bind_service+ep /usr/local/bin/hysteria 2>/dev/null || true
            fi
            # 内置 listen 端口范围模式需要 CAP_NET_ADMIN（调用 nft/iptables 需要）
            if [[ "$PORT_HOP" == "true" ]]; then
                if command -v setcap >/dev/null 2>&1 && [[ -x /usr/local/bin/hysteria ]]; then
                    info "内置 listen 端口范围模式需要 CAP_NET_ADMIN，已赋予 hysteria 二进制"
                    setcap cap_net_admin,cap_net_bind_service+ep /usr/local/bin/hysteria 2>/dev/null || true
                fi
            fi
            systemctl daemon-reload 2>/dev/null
            info "修复完成，再次尝试启动 ..."
            START_OK=true
            systemctl start hysteria-server 2>/dev/null || START_OK=false
            if ! $START_OK; then
                warn "修复后仍然失败，尝试终极兜底：临时改为 root 身份运行（拥有完整 nft/iptables 权限）..."
                sed -i 's/^User=hysteria/#User=hysteria/' "$SVC_FILE"
                sed -i 's/^Group=hysteria/#Group=hysteria/' "$SVC_FILE"
                systemctl daemon-reload 2>/dev/null
                START_OK=true
                systemctl start hysteria-server 2>/dev/null || START_OK=false
            fi
        else
            warn "未找到 service 文件，无法自动修复，请手动检查"
        fi
    fi
fi

echo ""
if $START_OK; then
    success "服务启动命令已执行"
    if [[ "$SSL_MODE" == "2" ]]; then
        info "内置 ACME 正在后台申请证书，请稍后通过以下命令检查运行状态："
        info "  systemctl status hysteria-server"
        info "  journalctl -u hysteria-server -f"
    else
        success "服务已正常启动"
    fi
else
    error "服务启动失败，请手动排查，以下是诊断命令："
    echo "       systemctl status hysteria-server -l --no-pager"
    echo "       journalctl -u hysteria-server -n 100 --no-pager"
    echo "       cat ${CONFIG_FILE}"
    echo "       /usr/local/bin/hysteria server --config ${CONFIG_FILE} 2>&1 | head -80"
fi
separator

# ============================================================
# 端口跳跃说明（HY2 内置 listen 范围模式）
# ============================================================
if [[ "$PORT_HOP" == "true" ]]; then
    step "端口跳跃说明"
    success "已使用 HY2 内置 listen: :${HOP_START}-${HOP_END} 端口范围模式"
    info "  · Hysteria2 会在启动时自动调用 nftables 或 iptables 建立重定向规则"
    info "  · 服务正常 stop 时会自动清理这些规则"
    info "  · 查看运行中的规则：iptables -t nat -L PREROUTING -n -v  或  nft list ruleset"
    warn "⚠️  请确保 VPS 防火墙/安全组放通 UDP+TCP 端口范围 ${HOP_START}-${HOP_END}"
    separator
fi

# ============================================================
# 安装完成 - 客户端信息交付
# ============================================================
step "安装完成"
echo ""
success "Hysteria v2 服务端已成功安装并启动！"
echo ""

if [[ "$SERVER_IP" == "你的服务器IP" ]]; then
    SERVER_IP=$(curl -s -4 --connect-timeout 8 icanhazip.com 2>/dev/null \
            || curl -s -4 --connect-timeout 8 ifconfig.me 2>/dev/null \
            || curl -s -4 --connect-timeout 8 ip.sb 2>/dev/null \
            || echo "你的服务器IP")
fi

if [[ "$SSL_MODE" == "1" ]]; then
    CLIENT_HOST="${SERVER_IP}"
else
    CLIENT_HOST="${REAL_DOMAIN}"
fi
CLIENT_PORT="${PORT}"

# === 保存客户端配置文件到 /root ===
CLIENT_FILE="/root/hy2-client-config.yaml"
info "正在保存客户端配置文件到: ${CLIENT_FILE}"

CLIENT_CONFIG_YAML="server: ${CLIENT_HOST}:${CLIENT_PORT}

auth: ${PASSWORD}

tls:
  sni: ${CLIENT_SNI}
  insecure: ${CLIENT_INSECURE}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080"

if [[ "$PORT_HOP" == "true" ]]; then
    CLIENT_CONFIG_YAML="${CLIENT_CONFIG_YAML}

# 端口跳跃（Hysteria2 内置 listen 范围模式，客户端直接指定范围即可）
# 官方客户端写法（把上方 server 替换成端口范围）：
# server: ${CLIENT_HOST}:${HOP_PORTS}"
fi

echo "${CLIENT_CONFIG_YAML}" > "${CLIENT_FILE}"
chmod 600 "${CLIENT_FILE}"
success "客户端配置已保存（权限 600）"

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                 客户端配置信息                     ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""
if [[ "$SSL_MODE" == "1" ]]; then
    echo -e "  ${YELLOW}证书类型:${NC}    自签名证书（客户端需 insecure=true）"
else
    echo -e "  ${YELLOW}证书类型:${NC}    真实 SSL 证书（Hysteria2 内置 ACME + Cloudflare DNS，自动申请/续期）"
fi
if [[ "$SSL_MODE" == "1" ]]; then
    echo -e "  ${YELLOW}服务器地址:${NC}  ${SERVER_IP}"
else
    echo -e "  ${YELLOW}服务器地址:${NC}  ${REAL_DOMAIN} (IP: ${SERVER_IP})"
fi
echo -e "  ${YELLOW}主端口:${NC}        ${PORT}"
if [[ "$PORT_HOP" == "true" ]]; then
    echo -e "  ${YELLOW}端口跳跃:${NC}      已启用（HY2 内置 listen 范围 ${HOP_PORTS}）"
fi
echo -e "  ${YELLOW}密码:${NC}          ${PASSWORD}"
echo -e "  ${YELLOW}协议:${NC}          Hysteria v2"
echo -e "  ${YELLOW}SNI:${NC}           ${CLIENT_SNI}"
echo -e "  ${YELLOW}证书验证:${NC}      insecure=${CLIENT_INSECURE}"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"

# ============ 1/3 hysteria2:// 分享链接 ============
echo ""
info "【1/3】Hysteria2 标准分享链接（NekoBox / Clash.Meta / v2rayN 等客户端一键导入）"
echo ""
ENC_AUTH=$(urlencode "${PASSWORD}")
ENC_SNI=$(urlencode "${CLIENT_SNI}")
HY2_PARAMS="sni=${ENC_SNI}"
[[ "${CLIENT_INSECURE}" == "true" ]] && HY2_PARAMS="${HY2_PARAMS}&insecure=1"
if [[ "$PORT_HOP" == "true" ]]; then
    HY2_PARAMS="${HY2_PARAMS}&mport=$(urlencode "${HOP_PORTS}")"
fi
ENC_NAME="HY2-${CLIENT_HOST}-${CLIENT_PORT}"
HY2_URI="hysteria2://${ENC_AUTH}@${CLIENT_HOST}:${CLIENT_PORT}?${HY2_PARAMS}#$(urlencode "${ENC_NAME}")"

echo -e "${GREEN}${HY2_URI}${NC}"
echo ""
info "👉 整条链接复制到剪贴板 → 客户端选「从剪贴板导入」即可"
if [[ "$PORT_HOP" == "true" ]]; then
    info "👉 端口跳跃范围已写入链接的 mport= 参数（${HOP_PORTS}）"
fi
echo ""

# ============ 2/3 官方客户端 config.yaml ============
info "【2/3】Hysteria2 官方客户端 config.yaml："
echo ""
echo -e "${YELLOW}${CLIENT_CONFIG_YAML}${NC}"
echo ""
info "已保存到: ${CLIENT_FILE}"
info "本机下载: scp root@${SERVER_IP}:${CLIENT_FILE} ./"
echo ""

# ============ 3/3 Clash.Meta proxy 片段 ============
info "【3/3】Clash.Meta / Mihomo proxy 片段："
echo ""
SKIP_VERIFY="${CLIENT_INSECURE}"
REMARK_NAME="HY2-${CLIENT_HOST}-${CLIENT_PORT}"

cat << EOF
- name: "${REMARK_NAME}"
  type: hysteria2
  server: ${CLIENT_HOST}
  port: ${CLIENT_PORT}
  password: "${PASSWORD}"
  sni: "${CLIENT_SNI}"
  skip-cert-verify: ${SKIP_VERIFY}
  alpn:
    - h3
EOF

if [[ "$PORT_HOP" == "true" ]]; then
cat << EOF
  # 端口跳跃（HY2 内置 listen 范围模式）
  hop-port: "${HOP_PORTS}"
  hop-interval: 30s
EOF
fi

echo ""
warn "⚠️  安全提示：以上密码和配置请妥善保管，不要泄露给他人"
echo ""

if [[ "$SSL_MODE" == "2" ]]; then
    warn "⚠️  请确保 Cloudflare 上 ${REAL_DOMAIN} 的 A 记录已解析到 ${SERVER_IP}"
    echo "       推荐：灰色云朵（仅 DNS 解析，不经过 CF 代理）"
    echo ""
fi

echo -e "${BLUE}常用管理命令：${NC}"
info "  查看服务状态:  systemctl status hysteria-server"
info "  查看服务日志:  journalctl -u hysteria-server -f"
info "  重启服务:      systemctl restart hysteria-server"
info "  停止服务:      systemctl stop hysteria-server"
info "  服务端配置:    ${CONFIG_FILE}"
info "  证书目录:      ${CERT_DIR}"
info "  客户端配置:    ${CLIENT_FILE}（可 scp 下载）"
if [[ "$SSL_MODE" == "2" ]]; then
    info "  ACME 缓存:     ${CERT_DIR}/acme（内置 ACME 自动续期）"
fi
if [[ "$PORT_HOP" == "true" ]]; then
    info "  端口跳跃:     内置 listen: :${HOP_START}-${HOP_END}（HY2 自动管理 nft/iptables）"
    info "  查看规则:     iptables -t nat -L PREROUTING -n | head  或  nft list ruleset"
fi
echo ""
echo -e "${GREEN}安装完成，祝你使用愉快！${NC}"
echo ""
