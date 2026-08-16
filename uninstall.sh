#!/bin/bash

# =========================
# Hysteria v2 交互式卸载脚本
# =========================

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

# --- 输入清洗：去除首尾空白 + 首尾反引号（与 install.sh 保持一致）---
sanitize_input() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    while [[ "${v:0:1}" == "\`" ]]; do v="${v:1}"; done
    while [[ -n "$v" && "${v: -1}" == "\`" ]]; do v="${v:0:${#v}-1}"; done
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    echo -n "$v"
}

# ============================================================
# 欢迎 & 警告
# ============================================================
clear
echo ""
echo -e "${RED}╔════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║            ⚠️  Hysteria v2 卸载脚本 ⚠️            ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════╝${NC}"
echo ""
warn "本脚本将从本服务器卸载 Hysteria v2 服务端"
warn "请仔细确认每一步，避免误删重要数据！"
warn "请确保以 root 或 sudo 权限运行此脚本"
echo ""

# --- 检查 root 权限 ---
if [[ $EUID -ne 0 ]]; then
    error "此脚本需要 root 权限运行，请使用 sudo 执行"
    exit 1
fi
success "权限检查通过"
separator

# --- 检测是否已安装 Hysteria2 ---
info "正在检测当前 Hysteria v2 安装状态 ..."
INSTALLED=false
SERVICE_EXISTS=false
CONFIG_EXISTS=false
USER_EXISTS=false
BINARY_EXISTS=false

command -v hysteria >/dev/null 2>&1 && BINARY_EXISTS=true
systemctl list-unit-files 2>/dev/null | grep -q hysteria-server && SERVICE_EXISTS=true
[[ -d /etc/hysteria ]] && CONFIG_EXISTS=true
id hysteria >/dev/null 2>&1 && USER_EXISTS=true

if $BINARY_EXISTS || $SERVICE_EXISTS || $CONFIG_EXISTS; then
    INSTALLED=true
    echo ""
    info "检测结果："
    echo "  - 服务二进制(hysteria):  $($BINARY_EXISTS && echo -e "${GREEN}已安装${NC}" || echo -e "${YELLOW}未发现${NC}")"
    echo "  - systemd 服务单元:       $($SERVICE_EXISTS && echo -e "${GREEN}已存在${NC}" || echo -e "${YELLOW}未发现${NC}")"
    echo "  - /etc/hysteria 目录:     $($CONFIG_EXISTS && echo -e "${GREEN}已存在${NC} $(du -sh /etc/hysteria 2>/dev/null | cut -f1)" || echo -e "${YELLOW}未发现${NC}")"
    echo "  - hysteria 用户/组:       $($USER_EXISTS && echo -e "${GREEN}已存在${NC}" || echo -e "${YELLOW}未发现${NC}")"
    echo ""
else
    error "未检测到任何 Hysteria v2 相关文件或服务，卸载脚本退出"
    exit 0
fi

# ============================================================
# 卸载选项确认
# ============================================================
step "卸载选项确认"
echo ""
warn "请依次确认以下卸载项（输入 y/Y/yes/YES 执行，n/N/no/NO 跳过，直接回车=默认）："
echo ""

# 1. 停止并禁用服务
UNINSTALL_SERVICE=false
if $SERVICE_EXISTS; then
    read -p "[1/6] 停止并禁用 hysteria-server 服务？[y/n]: " C
    parse_yesno "$C" "y" && UNINSTALL_SERVICE=true
else
    info "跳过：未检测到 hysteria-server 服务单元"
fi

# 2. 卸载二进制文件和 systemd 单元
UNINSTALL_BINARY=false
if $BINARY_EXISTS || $SERVICE_EXISTS; then
    echo ""
    read -p "[2/6] 卸载 Hysteria v2 二进制文件和 systemd 单元？[y/n]: " C
    parse_yesno "$C" "y" && UNINSTALL_BINARY=true
else
    info "跳过：未检测到 Hysteria v2 二进制或服务单元"
fi

# 3. 删除配置与证书目录
REMOVE_CONFIG=false
if $CONFIG_EXISTS; then
    echo ""
    warn "⚠️  以下目录将被永久删除（含配置、证书、ACME 缓存）："
    echo "       /etc/hysteria/"
    ls /etc/hysteria/ 2>/dev/null | sed 's/^/         - /'
    echo ""
    read -p "[3/6] 确认删除 /etc/hysteria/ 整个目录？[y/n]: " C
    parse_yesno "$C" "n" && REMOVE_CONFIG=true
else
    info "跳过：未检测到 /etc/hysteria/ 目录"
fi

# 4. 删除 hysteria 用户和组
REMOVE_USER=false
if $USER_EXISTS; then
    echo ""
    read -p "[4/6] 删除 hysteria 用户和组？[y/n]: " C
    parse_yesno "$C" "n" && REMOVE_USER=true
else
    info "跳过：未检测到 hysteria 用户"
fi

# 5. 清理端口跳跃相关的 iptables 规则 / hy2-port-hop oneshot 服务 / 持久化规则文件
# （HY2 内置 listen 范围模式由 HY2 自己启动时自动创建、停止时自动清理；
#   这里只清理脚本手动设置的 iptables/oneshot/规则文件）
REMOVE_PORT_HOP=false
HOP_ONESHOT_SERVICE="/etc/systemd/system/hy2-port-hop.service"
HOP_RULES_FILE="/etc/iptables.hy2.rules.v4"
EXIST_HOP_IPTABLES=false
EXIST_HOP_ONESHOT=false
EXIST_HOP_RULESFILE=false
if command -v iptables >/dev/null 2>&1 && iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'hy2:port-hop'; then
    EXIST_HOP_IPTABLES=true
fi
[[ -f "$HOP_ONESHOT_SERVICE" ]] && EXIST_HOP_ONESHOT=true
[[ -f "$HOP_RULES_FILE" ]] && EXIST_HOP_RULESFILE=true

if $EXIST_HOP_IPTABLES || $EXIST_HOP_ONESHOT || $EXIST_HOP_RULESFILE; then
    echo ""
    warn "⚠️  检测到脚本创建的端口跳跃遗留组件："
    $EXIST_HOP_IPTABLES   && echo "       · iptables NAT 规则（含 hy2:port-hop 注释）"
    $EXIST_HOP_ONESHOT   && echo "       · oneshot 服务: ${HOP_ONESHOT_SERVICE}"
    $EXIST_HOP_RULESFILE && echo "       · 持久化规则文件: ${HOP_RULES_FILE}"
    echo ""
    read -p "[5/6] 清理端口跳跃相关 iptables 规则 / oneshot 服务 / 规则文件？[y/n]: " C
    parse_yesno "$C" "y" && REMOVE_PORT_HOP=true
else
    info "跳过：未检测到脚本创建的端口跳跃遗留组件"
fi

# 6. 清理可能存在的外部 acme.sh 签发的证书（兼容历史版本）
REMOVE_ACME_SH_CERT=false
ACME_SH_BIN="$HOME/.acme.sh/acme.sh"
HAS_ACME_SH_CERTS=false
if [[ -x "$ACME_SH_BIN" ]]; then
    if [[ -d "$HOME/.acme.sh" ]]; then
        CERTS_FOUND=$(find "$HOME/.acme.sh" -maxdepth 2 -name "*.cer" 2>/dev/null | head -20)
        if [[ -n "$CERTS_FOUND" ]]; then
            HAS_ACME_SH_CERTS=true
        fi
    fi
fi

if $HAS_ACME_SH_CERTS; then
    echo ""
    warn "⚠️  检测到 ~/.acme.sh 目录，可能包含为 Hysteria 签发的证书"
    warn "    如果你之前使用外部 acme.sh 模式签发过证书，可以选择一并清理"
    read -p "[6/6] 清理？【输入 ALL=完全卸载 acme.sh，CERT=仅吊销/删证书，N=跳过】[CERT/all/N]: " C
    # 转小写后判断，aLl/aLL/All/ALL/cert/CERT/Cert 都兼容
    C_LOWER="${C,,}"
    [[ -z "$C_LOWER" ]] && C_LOWER="cert"   # 默认值=CERT（提示里写的 CERT/all/N 所以默认 cert 更贴近原意，但为了安全其实默认 N 也行，看历史逻辑——历史逻辑是 C=${C:-N}，然后 tr 大写，CERT 写了默认所以... 这里安全起见默认 N）
    # 重新处理：默认=N（与历史逻辑一致，因为如果检测到证书默认也不应该直接删）
    if [[ -z "${C,,}" ]]; then
        C_LOWER="n"
    fi
    case "$C_LOWER" in
        all)  REMOVE_ACME_SH_CERT="ALL" ;;
        cert) REMOVE_ACME_SH_CERT="CERT" ;;
        *)    REMOVE_ACME_SH_CERT=false ;;
    esac
else
    if [[ -d "$HOME/.acme.sh" ]]; then
        echo ""
        read -p "[6/6] 检测到 ~/.acme.sh 目录，是否一并卸载 acme.sh 工具？[y/n]: " C
        parse_yesno "$C" "n" && REMOVE_ACME_SH_CERT="ALL"
    else
        info "跳过：未检测到 ~/.acme.sh 目录"
    fi
fi

# ===== 最终确认 =====
separator
echo ""
warn "═════════════ 请再次确认以下卸载操作 ═════════════"
echo "   停止并禁用服务:            $($UNINSTALL_SERVICE && echo -e "${RED}是${NC}" || echo "否")"
echo "   卸载二进制+systemd单元:    $($UNINSTALL_BINARY && echo -e "${RED}是${NC}" || echo "否")"
echo "   删除 /etc/hysteria 目录:   $($REMOVE_CONFIG && echo -e "${RED}是（不可恢复）${NC}" || echo "否")"
echo "   删除 hysteria 用户/组:     $($REMOVE_USER && echo -e "${RED}是${NC}" || echo "否")"
echo "   清理端口跳跃(iptables/oneshot): $($REMOVE_PORT_HOP && echo -e "${RED}是${NC}" || echo "否")"
if [[ "$REMOVE_ACME_SH_CERT" == "ALL" ]]; then
    echo "   清理外部 acme.sh:          ${RED}完全卸载 acme.sh${NC}"
elif [[ "$REMOVE_ACME_SH_CERT" == "CERT" ]]; then
    echo "   清理外部 acme.sh:          ${RED}仅吊销/删除证书${NC}"
else
    echo "   清理外部 acme.sh:          否"
fi
warn "═══════════════════════════════════════════════════"
echo ""
read -p "$(echo -e ${RED})确认执行以上卸载操作？输入 YES（或 yes）继续，其他任意键退出：$(echo -e ${NC}) " FINAL
echo ""

FINAL_LOWER="${FINAL,,}"
if [[ "$FINAL_LOWER" != "yes" ]]; then
    info "已取消卸载，脚本退出"
    exit 0
fi

separator

# ============================================================
# 执行卸载
# ============================================================
step "开始执行卸载"

# 1. 停止并禁用服务
if $UNINSTALL_SERVICE; then
    echo ""
    info "[1/6] 正在停止 hysteria-server 服务 ..."
    if systemctl stop hysteria-server 2>/dev/null; then
        success "服务已停止"
    else
        warn "停止服务命令执行失败（可能服务未运行）"
    fi

    info "正在禁用 hysteria-server 开机自启 ..."
    if systemctl disable hysteria-server 2>/dev/null; then
        success "已禁用开机自启"
    else
        warn "禁用开机自启命令执行失败"
    fi
    systemctl daemon-reload 2>/dev/null
else
    info "[1/6] 跳过：停止/禁用服务"
fi

# 2. 卸载二进制和 systemd 单元
if $UNINSTALL_BINARY; then
    echo ""
    info "[2/6] 正在卸载 Hysteria v2 二进制和 systemd 单元 ..."
    TMP_UNINSTALL="/tmp/get_hy2_uninstall.sh"
    if curl -fsSL -o "$TMP_UNINSTALL" https://get.hy2.sh/ 2>/dev/null; then
        if grep -qE '(--uninstall|-u|uninstall)' "$TMP_UNINSTALL" 2>/dev/null; then
            info "调用官方脚本卸载 ..."
            bash "$TMP_UNINSTALL" --remove 2>/dev/null || bash "$TMP_UNINSTALL" --uninstall 2>/dev/null || true
            rm -f "$TMP_UNINSTALL"
        fi
        rm -f "$TMP_UNINSTALL"
    fi

    info "执行手动兜底清理 ..."
    for f in /usr/local/bin/hysteria /usr/bin/hysteria /usr/local/sbin/hysteria; do
        if [[ -f "$f" ]]; then
            rm -f "$f" && success "已删除: $f"
        fi
    done
    for f in /etc/systemd/system/hysteria-server.service \
             /etc/systemd/system/hysteria-server@.service \
             /lib/systemd/system/hysteria-server.service \
             /usr/lib/systemd/system/hysteria-server.service; do
        if [[ -f "$f" ]]; then
            rm -f "$f" && success "已删除: $f"
        fi
    done
    systemctl daemon-reload 2>/dev/null
    success "二进制与 systemd 单元清理完成"
else
    info "[2/6] 跳过：卸载二进制和 systemd 单元"
fi

# 3. 删除 /etc/hysteria 目录
if $REMOVE_CONFIG; then
    echo ""
    info "[3/6] 正在删除 /etc/hysteria/ 目录 ..."
    if rm -rf /etc/hysteria; then
        success "目录已删除: /etc/hysteria/"
    else
        error "目录删除失败，请手动检查"
    fi
else
    info "[3/6] 跳过：删除配置目录"
fi

# 4. 删除 hysteria 用户/组
if $REMOVE_USER; then
    echo ""
    info "[4/6] 正在删除 hysteria 用户和组 ..."
    if id hysteria >/dev/null 2>&1; then
        if userdel -r hysteria 2>/dev/null; then
            success "hysteria 用户已删除（含家目录）"
        else
            warn "userdel -r 失败，尝试普通删除..."
            userdel hysteria 2>/dev/null && success "hysteria 用户已删除" || error "删除用户失败"
        fi
    fi
    if getent group hysteria >/dev/null 2>&1; then
        groupdel hysteria 2>/dev/null && success "hysteria 组已删除" || error "删除组失败"
    fi
else
    info "[4/6] 跳过：删除 hysteria 用户/组"
fi

# 5. 清理端口跳跃 iptables 规则 / oneshot 服务 / 规则文件
echo ""
if $REMOVE_PORT_HOP; then
    info "[5/6] 正在清理端口跳跃 iptables 规则 / oneshot 服务 ..."

    # 5.1 oneshot 服务先停/禁用/删除，否则下次开机又加载回来了
    if [[ -f "$HOP_ONESHOT_SERVICE" ]]; then
        systemctl stop hy2-port-hop 2>/dev/null || true
        systemctl disable hy2-port-hop 2>/dev/null || true
        rm -f "$HOP_ONESHOT_SERVICE" \
            && success "已删除 oneshot 服务: ${HOP_ONESHOT_SERVICE}" \
            || error "删除 oneshot 服务失败: ${HOP_ONESHOT_SERVICE}"
        systemctl daemon-reload 2>/dev/null || true
    fi

    # 5.2 规则文件
    if [[ -f "$HOP_RULES_FILE" ]]; then
        rm -f "$HOP_RULES_FILE" \
            && success "已删除持久化规则文件: ${HOP_RULES_FILE}" \
            || error "删除规则文件失败: ${HOP_RULES_FILE}"
    fi

    # 5.3 iptables NAT 规则（按 hy2:port-hop 注释精准删除）
    if command -v iptables >/dev/null 2>&1; then
        REMOVED_CNT=0
        while iptables -t nat -S PREROUTING 2>/dev/null | grep 'hy2:port-hop' | head -n 1 | read -r line; do
            [[ -z "$line" ]] && break
            # -S 输出的是 "-A PREROUTING -p udp ...", 把 -A 换成 -D 再执行就是删除
            del_cmd=$(echo "$line" | sed 's/^-A/-D/')
            if iptables -t nat $del_cmd 2>/dev/null; then
                REMOVED_CNT=$((REMOVED_CNT+1))
            fi
            # 避免 grep 没变化时死循环（虽然 while read 每次读新，但 grep 输出其实是一次全读出来，所以要保险）
            [[ $REMOVED_CNT -gt 500 ]] && break
        done
        # 再跑一次兜底，应对 shell pipe subshell 里变量不回传的问题
        if iptables -t nat -S PREROUTING 2>/dev/null | grep -q 'hy2:port-hop'; then
            iptables -t nat -S PREROUTING 2>/dev/null | grep 'hy2:port-hop' | sed 's/^-A/-D/' | while read -r d; do
                [[ -n "$d" ]] && iptables -t nat $d 2>/dev/null || true
            done
        fi
        # IPv6 同样处理（脚本 install.sh 里没手动加 ip6tables 规则，但如果手动加了也一起清）
        if command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -t nat -S PREROUTING 2>/dev/null | grep 'hy2:port-hop' | head -n 1 | read -r line; do
                [[ -z "$line" ]] && break
                del_cmd=$(echo "$line" | sed 's/^-A/-D/')
                ip6tables -t nat $del_cmd 2>/dev/null || true
                break
            done
            ip6tables -t nat -S PREROUTING 2>/dev/null | grep 'hy2:port-hop' | sed 's/^-A/-D/' | while read -r d; do
                [[ -n "$d" ]] && ip6tables -t nat $d 2>/dev/null || true
            done
        fi
        success "已清理 iptables NAT 中 hy2:port-hop 相关规则"
    else
        warn "未找到 iptables 命令，跳过 iptables 规则清理"
    fi

    # 5.4 如果 Debian/Ubuntu 用了 netfilter-persistent，重存一下（不然重启又回来了）
    if command -v netfilter-persistent >/dev/null 2>&1; then
        info "检测到 netfilter-persistent，正在重新保存当前规则..."
        if command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        netfilter-persistent save 2>/dev/null || netfilter-persistent reload 2>/dev/null || true
        success "netfilter-persistent 规则已刷新"
    fi

    # 5.5 如果 CentOS/RHEL 用了 iptables-services，重存一下
    if [[ -f /etc/sysconfig/iptables-config ]] && command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null && success "已更新 /etc/sysconfig/iptables（iptables-services）"
    fi
else
    info "[5/6] 跳过：端口跳跃组件清理"
fi

# 6. 清理外部 acme.sh 证书 / 卸载
echo ""
if [[ "$REMOVE_ACME_SH_CERT" == "ALL" ]]; then
    info "[6/6] 正在完全卸载 acme.sh ..."
    if [[ -x "$ACME_SH_BIN" ]]; then
        "$ACME_SH_BIN" --uninstall 2>/dev/null && success "acme.sh 已卸载" || warn "acme.sh --uninstall 返回非零，尝试手动清理"
    fi
    if [[ -d "$HOME/.acme.sh" ]]; then
        rm -rf "$HOME/.acme.sh" && success "已删除目录: $HOME/.acme.sh"
    fi
    for rcfile in $HOME/.bashrc $HOME/.bash_profile $HOME/.profile $HOME/.zshrc; do
        [[ -f "$rcfile" ]] && sed -i '/\.acme.sh/d' "$rcfile" 2>/dev/null
    done
    success "acme.sh 完全清理完成"
elif [[ "$REMOVE_ACME_SH_CERT" == "CERT" ]]; then
    info "[6/6] 正在吊销并删除 ~/.acme.sh 中签发的证书 ..."
    if [[ -x "$ACME_SH_BIN" ]]; then
        "$ACME_SH_BIN" --list 2>/dev/null | while IFS='|' read -r d _ _ _ _; do
            d=$(echo "$d" | xargs)
            [[ -z "$d" || "$d" == "Main_Domain" ]] && continue
            info "  - 清理证书: $d"
            "$ACME_SH_BIN" --remove -d "$d" 2>/dev/null || true
        done
        success "已清理 acme.sh 中的证书记录"
    else
        warn "未找到 acme.sh 可执行文件，跳过自动吊销"
    fi
else
    info "[6/6] 跳过：外部 acme.sh 清理"
fi

separator

# ============================================================
# 卸载完成
# ============================================================
step "卸载完成"
echo ""
success "Hysteria v2 卸载流程执行完毕！"
echo ""
info "残留检测："
BINARY_EXISTS2=false; command -v hysteria >/dev/null 2>&1 && BINARY_EXISTS2=true
SERVICE_EXISTS2=false; systemctl list-unit-files 2>/dev/null | grep -q hysteria-server && SERVICE_EXISTS2=true
CONFIG_EXISTS2=false; [[ -d /etc/hysteria ]] && CONFIG_EXISTS2=true
USER_EXISTS2=false; id hysteria >/dev/null 2>&1 && USER_EXISTS2=true

echo "  - 服务二进制(hysteria):  $($BINARY_EXISTS2 && echo -e "${YELLOW}仍存在${NC}" || echo -e "${GREEN}已清除${NC}")"
echo "  - systemd 服务单元:       $($SERVICE_EXISTS2 && echo -e "${YELLOW}仍存在${NC}" || echo -e "${GREEN}已清除${NC}")"
echo "  - /etc/hysteria 目录:     $($CONFIG_EXISTS2 && echo -e "${YELLOW}仍存在${NC}" || echo -e "${GREEN}已清除${NC}")"
echo "  - hysteria 用户/组:       $($USER_EXISTS2 && echo -e "${YELLOW}仍存在${NC}" || echo -e "${GREEN}已清除${NC}")"
echo ""
if ! $BINARY_EXISTS2 && ! $SERVICE_EXISTS2 && ! $CONFIG_EXISTS2 && ! $USER_EXISTS2; then
    success "🎉 所有检测项均已清除，卸载彻底完成"
else
    warn "部分项目仍存在，你可以手动清理或重新运行此脚本"
fi
echo ""
info "感谢使用 Hysteria v2！"
echo ""
