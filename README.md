# Hysteria 2 一键交互式安装脚本

> 全程回车式提问，零手动改配置文件。装完直接给 **客户端配置 + hysteria2:// 链接 + Clash.Meta 片段**，复制就能用。

---

## ⚡ 一句话速装（服务器上执行）

```bash
# 1. 上传 install.sh / uninstall.sh 到服务器
chmod +x install.sh uninstall.sh

# 2. 开装（回车式提问）
./install.sh
```

装完会在终端打印「客户端配置交付面板」，把密码、域名、跳跃端口全部拼好，复制粘贴即可。

---

## ✅ 脚本解决了什么痛点

| 痛点 | 本脚本做法 |
|------|-----------|
| 每次装都要翻模板改 YAML | 交互式询问，回车就生成 `/etc/hysteria/config.yaml` |
| 端口跳跃要自己写一长串 iptables 还要持久化 | **直接用 HY2 官方内置 `listen: :起始-结束`，HY2 自己加/删 nft/iptables NAT 规则，你一条 iptables 都不用写**（详见下文「端口跳跃原理」） |
| 真实证书 CF 凭证类型经常搞混（Token vs Global Key） | **只支持 libdns/cloudflare 官方唯一识别的 `cloudflare_api_token`（cfut_ 细粒度 Token），不再有 Global + Email 双字段**，从源头避免 Cloudflare `6003 Invalid request headers` |
| CentOS 7 启动报 `218/CAPABILITIES` | 自动识别 systemd < 229，注释掉 `AmbientCapabilities` 并 `setcap`，回退 root 用户运行 |
| 装完不知道怎么给客户端 | 自动输出 3 份：HY2 官方客户端 YAML / hysteria2:// 分享链接 / Clash.Meta 片段，跳跃端口参数已经写进 `mport=`/`ports=` |
| 卸载不干净 | `uninstall.sh` 六步逐项 `[y/n]` 确认，服务 + 二进制 + 配置 + 用户组 + 遗留 oneshot/iptables 全部清干净 |
| 交互提示 Y/n 大小写乱 | **所有确认提示符统一为 `[y/n]` 小写**，同时兼容 `y/Y/yes/YES n/N/no/NO` |

---

## 🖥️ 支持系统（脚本会前自动检测）

| 系统 | 支持情况 |
|------|---------|
| Debian 10/11/12 · Ubuntu 18.04~24.04 | ✅ 完全支持 |
| CentOS 7/8/9 Stream · RHEL · AlmaLinux · Rocky | ✅ 兼容（自动修 `218/CAPABILITIES`） |
| OpenWrt · 非 systemd 系统 | ❌ 拒绝安装 |
| LXC / OpenVZ / NAT 小鸡 | ⚠️ 单端口 OK；端口跳跃需要宿主机开放 `nat` 表，**绝大多数容器 NAT 表不可用，会失败，直接不启用跳跃即可** |

前置依赖：`curl` + `openssl` + `systemd` + 能访问 `https://get.hy2.sh/`。

---

## 🎯 交互式流程（跟着回车就行）

下面是**完整交互过程**，可以提前准备信息。

### ① 环境自检 + 确认继续
```
============================================================
 Hysteria v2 一键交互式安装脚本
============================================================
[前置检测] 正在检测当前系统环境 ...
   - 操作系统: Ubuntu 22.04.5 LTS (debian)
   - CPU 架构: x86_64 (amd64)
   - systemd: 版本 249 -> 支持
   - 依赖工具: curl ✓  openssl ✓
   - 公网 IPv4: 1.2.3.4
   - 公网 IPv6: 未检测到
[前置检测] 是否继续安装？[y/n]: y
```

### ② 主监听端口 + 端口跳跃（重点！）
```
[端口] 请输入主监听端口 [默认: 443]: 443

[端口跳跃] 是否启用端口跳跃？[y/n]: y
   · 请输入跳跃范围，格式：起始端口-结束端口（如 20000-50000）: 20000-50000
[端口跳跃] 设置完成: listen=:20000-50000，主端口=20000，其余由 HY2 自动 NAT 重定向
```

> ### 🚩 端口跳跃原理（你不用写任何 iptables）
> HY2 官方文档「内置端口范围（仅 Linux）」原文：
>
> > 服务器将监听范围内的第一个端口，并自动设置防火墙规则（使用 nftables 或 iptables）将其他端口的流量重定向到第一个端口。服务器关闭时会自动清理这些规则。
>
> 翻译成人话：
> 1. 你只需要 `listen: :20000-50000`，**HY2 实际只 listen 20000（第一个端口）**；
> 2. 启动时 HY2 自己调用 `nft`（优先）或 `iptables` 写入 `nat PREROUTING dport 20001:50000 REDIRECT to :20000`；
> 3. **`systemctl stop hysteria-server` 收到 SIGTERM 时，HY2 自己删掉刚才写的规则**，不需要你做持久化、不需要开机再跑一遍；
> 4. `CAP_NET_ADMIN` 脚本已通过 `setcap` 赋予。
>
> ❌ 你之前在网上看到的那两条：
> ```
> iptables  -t nat -A PREROUTING -i eth0 -p udp --dport 20000:50000 -j REDIRECT --to-ports 20000
> ip6tables -t nat -A PREROUTING -i eth0 -p udp --dport 20000:50000 -j REDIRECT --to-ports 20000
> ```
> **完全不要再加了**。加了会被 REDIRECT 两次，行为不可控。

### ③ 连接密码
```
[认证] 请输入连接密码 [默认: 随机 12 位]: a970a7e3b
[认证] 使用密码: a970a7e3b
```
直接回车就自动生成强密码，最后会和链接一起打印。

### ④ 证书模式选择
```
[证书模式] 请选择证书模式：
   1) 自签证书（无需域名，客户端需 insecure=true）
   2) 真实 SSL 证书（内置 ACME + Cloudflare DNS，域名 + cfut_ Token）
请选择 [1 或 2，默认: 2]: 2
```

#### 模式 1：自签证书（无域名）
```
请输入自签证书的 SNI/CN 伪装域名 [默认: bing.com]: bing.com
```
客户端必须 `insecure=true`（HY2 客户端）/ `skip-cert-verify: true`（Clash.Meta）。

#### 模式 2：真实证书（内置 ACME + Cloudflare DNS）🚩
```
真实证书模式需要：
   - 域名 DNS 托管在 Cloudflare，且 A 记录已指向本服务器 IP（建议灰色云朵仅 DNS）
   - 凭证必须是 Cloudflare「API Token」（权限：Zone - Read + Zone - DNS - Edit，前缀通常是 cfut_）
   - 证书由 Hysteria2 启动时自动申请并自动续期（内置 ACME 目录：/etc/hysteria/acme）

请输入用于 Hysteria 的完整域名（如 hy.example.com）: hy2.example.com
请输入 ACME 账户联系邮箱（用于证书到期提醒，可留空）: you@example.com
请输入 Cloudflare API Token（Zone:Read + Zone.DNS:Edit 权限）: cfut_UgpVxWxD6uE8a3HORTiERL8gKMetJ5x9SpZkkZKd0c674be8
```

> ### 🚩 Cloudflare DNS API Token 创建完整步骤（别再用 Global API Key！）
> Hysteria2 用的是 `libdns/cloudflare`，**官方只支持单字段 `cloudflare_api_token`，不支持旧版 `Global API Key + Email`**。所以你拿 Token 的正确姿势是创建一个「细粒度权限的 User Token」（前缀 `cfut_`），步骤如下（建议在 PC 浏览器里操作）：
>
> #### Step 1：进入 API Tokens 页面
> 1. 浏览器打开并登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)；
> 2. 点右上角**头像图标**（你的账号头像）→ 在下拉菜单里选 **"My Profile"**（我的个人资料）；
> 3. 在左侧菜单里点 **"API Tokens"**（或者直接访问 [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)）；
> 4. 进入页面后你会看到三块：
>    - **API Tokens**（你要的就是这个，下面的 Create Token 按钮）
>    - **API Keys**（这里面有个 "Global API Key" —— 不要用这个！旧版双字段 `libdns` 根本不认，HY2 会直接报 Cloudflare `Code:6003 Invalid request headers / 6111 Invalid format`）
>
> #### Step 2：点 Create Token → 选择「Edit zone DNS」模板
> 1. 在 "API Tokens" 区域点蓝色按钮 **"Create Token"**；
> 2. 页面跳到 "Create a token"，往下找到 **"API token templates"**（API 令牌模板）；
> 3. 在模板列表里找到 **"Edit zone DNS"**（编辑区域 DNS）→ 点右边蓝色 **"Use template"**（使用模板）按钮。
>
> #### Step 3：配置权限、作用域、有效期（最小权限最安全）
> 进入 "Permissions / Zone Resources / TTL / Client IP Address Filtering" 配置页：
>
> 1. **Permissions（权限）** —— 模板已自动帮你填好，**保持默认即可**：
>    - `Zone` - `DNS` - `Edit`（必须，用来写 `_acme-challenge` 的 TXT 记录）
>    - 可选（模板默认带）：`Zone` - `Zone` - `Read`（读取 zone 信息，找根域用）→ 保留
>
> 2. **Zone Resources（区域资源）** —— 关键，别选 "All zones"（太大权限），按实际情况缩小范围：
>    - 选 **"Include"（包含）** → **"Specific zone"（特定区域）** → 在下拉框里选你要用的那个根域（例如 `kdns.fr` / `example.com`）；
>    - 如果你有多个独立域名需要申请证书，就选 **"All zones in a specific account"（特定账户下的所有区域）**，或者创建后再加 "Zone Resources - Include - Specific zone" 加多条。
>
> 3. **TTL（有效期）** —— 因为 HY2 续期要一直用这个 Token，所以默认是 **"Start: Now，End: Never"（永不过期）**，保持默认即可；如果担心泄露，也可以设一年后到期，到期前再来创建新的。
>
> 4. **Client IP Address Filtering（客户端 IP 过滤，可选）** —— 如果你只想让这台服务器的 IP 能用这个 Token，就勾选上，填上服务器出口公网 IP（脚本安装时检测到的那个 `公网 IPv4: x.x.x.x`）。这样就算 Token 泄露，别人 IP 不对也用不了。
>
> 全部配好后，点页面底部的蓝色按钮 **"Continue to summary"（继续以显示摘要）**。
>
> #### Step 4：确认摘要 → 创建
> 摘要页面会列出 "Permissions / Zone Resources / TTL / IP Filtering"，确认无误后点 **"Create Token"**（创建令牌）。
>
> #### Step 5：立刻复制保存（只显示这一次！）
> 页面会跳转到 "Your API token has been created"：
> ```
> Token: cfut_UgpVxWxD6uE8a3HORTiERL8gKMetJ5x9SpZkkZKd0c674be8
> ```
> - **把这一行完整复制（前缀是 `cfut_`）**，页面会提醒 "Just like a password, store it in a secure location, it won't be shown again."（过了这一页再也看不到）；
> - 这个 Token 就是你在脚本交互里要粘贴到 **"请输入 Cloudflare API Token"** 的值。
>
> #### Step 6：可选 —— 用 curl 立刻验证 Token 有效再装
> 想避免 HY2 启动后才发现 Token 权限不对？先在服务器上跑这一条验证：
> ```bash
> CF_TOKEN="cfut_把你的Token粘到这里"
> curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
>   -H "Authorization: Bearer ${CF_TOKEN}" \
>   -H "Content-Type:application/json" | python3 -m json.tool
> ```
> 看到 `"status": "active"` 且 `"message": "This API Token is valid and active"` 就说明 Token 本身有效；下一步再验证它对目标 Zone 有没有 DNS 写权限：
> ```bash
> ZONE_NAME="kdns.fr"   # 替换成你自己的根域，不是完整 hy2.xxx
> curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}&status=active" \
>   -H "Authorization: Bearer ${CF_TOKEN}" | python3 -m json.tool
> ```
> 能返回一条 result（含 id=32 位 hash）说明 Zone:Read OK。拿不到 result，就是 Zone Resources 没包含这个根域，回去 Step 3 改。
>
> #### 为什么别用 Global API Key？
> Global API Key 存在 **"API Keys"** 那块（前缀常是 `cfk_` 或直接纯 hex），特点是：
> - 拥有你这个 Cloudflare 账号**所有 Zone、所有产品**的全部权限（相当于 root 密码），一旦泄露非常危险；
> - **`libdns/cloudflare` 的 Provider struct 只有 `APIToken string` 一个公开字段**，压根就没有 Email + Key 两个输入的位置。所以不管你在 HY2 配置里写成 `CF_API_EMAIL / CF_API_KEY` 还是 `cloudflare_api_email / cloudflare_api_key`（大写或小写下划线），libdns 都读不到，最终 Cloudflare API 请求带空 headers → 直接回 `HTTP 400 Code:6003 Invalid request headers / Code:6111 Invalid format`。
>
> 所以：**请一律按上面 6 步创建 `cfut_` 前缀的细粒度 User Token**，这是 HY2 唯一支持的凭证格式。

### ⑤ 伪装地址
```
请输入伪装网站地址 [默认: https://www.bing.com]:
```
非 HY2 探测流量会被反代到这个 URL，填任意 HTTPS 站点即可。脚本会自动剥掉首尾反引号，直接粘贴没问题。

### ⑥ 最终确认 + 安装
```
═════════════ 请确认以下配置信息 ═════════════
   listen 写法:    :20000-50000（HY2 内置端口范围，主端口=20000）
   端口跳跃:      已启用（HY2 内置 listen 范围，自动 nft/iptables）
   连接密码:      a970a7e3b
   证书类型:      真实 SSL 证书 (内置 ACME + Cloudflare DNS)
   证书域名:      hy2.example.com
   ACME 邮箱:     you@example.com
   CF 凭证:       API Token: cfut****74be
   伪装地址:      https://www.bing.com
═══════════════════════════════════════════════
确认以上配置无误，开始安装？[y/n]: y
```

回车后脚本依次执行：下载安装 HY2 → 生成证书 / ACME 目录 → 写 config.yaml → 写 systemd + setcap → 启动服务并跟日志 20 秒。如果中途启动报 `218/CAPABILITIES`（CentOS 7 常见），自动修。

---

## 📦 装完交付：复制直接用

装成功终端会打印这三份，直接复制：

### ① HY2 官方客户端 `config.yaml`
```yaml
server: hy2.example.com:20000
auth: a970a7e3b
tls:
  sni: hy2.example.com
  insecure: false
transport:
  udp:
    hopInterval: 30s
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  connReceiveWindow: 20971520
  maxIncomingStreams: 1024
  maxIncomingUniStreams: 1024
masquerade:
  type: string
  string:
    payload: "https://www.bing.com"
mport: "20000-50000"
```
> 不开跳跃的话不会有 `transport.udp.hopInterval` 和 `mport:`。

### ② `hysteria2://` 分享链接
```
hysteria2://a970a7e3b@hy2.example.com:20000?mport=20000-50000&insecure=0&sni=hy2.example.com#HY2-hy2.example.com
```
> 小火箭 / Stash / v2rayN / v2rayNG / NekoBox / 官方移动端，扫码或粘贴直接导入。

### ③ Clash.Meta / Mihomo 片段
```yaml
- name: HY2-hy2.example.com
  type: hysteria2
  server: hy2.example.com
  port: 20000
  ports: 20000-50000
  password: a970a7e3b
  sni: hy2.example.com
  skip-cert-verify: false
  hop-interval: 30s
```

---

## 📂 路径一览

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/hysteria` | 官方二进制（`get.hy2.sh` 安装） |
| `/etc/hysteria/config.yaml` | 脚本生成的配置文件，改完要 `systemctl restart` |
| `/etc/hysteria/server.crt` + `server.key` | 自签证书（选模式 1 才有） |
| `/etc/hysteria/acme/` | ACME 账户、已签证书、缓存（选模式 2 才有） |
| `/etc/systemd/system/hysteria-server.service` | systemd unit |

---

## 🛠 日常命令

```bash
systemctl status  hysteria-server           # 看状态
systemctl restart hysteria-server           # 改完配置后重启
journalctl -u hysteria-server -f            # 实时看日志（证书申请、NAT 规则写入都在这）
journalctl -u hysteria-server -n 200 --no-pager   # 查看最新 200 行日志

hysteria version
hysteria server --check -c /etc/hysteria/config.yaml   # 手动校验配置语法
```

### 验证端口跳跃是否生效
```bash
# ▶ 启动后看 HY2 加了哪些规则
journalctl -u hysteria-server --since "1 min ago" | grep -iE "firewall|nft|iptab|redirect"

# 方法一：nftables（HY2 优先走这个）
nft list ruleset 2>/dev/null | grep -E "hysteria|20000|REDIRECT"

# 方法二：iptables 回退
iptables  -t nat -S PREROUTING | grep -E "20000:50000|REDIRECT"
ip6tables -t nat -S PREROUTING | grep -E "20000:50000|REDIRECT"

# ▶ 停止服务后，规则应该被 HY2 自动删掉
systemctl stop hysteria-server
# 再执行上面的 grep，应该空了
```

---

## 🆑 卸载（六步逐个问 `[y/n]`）

```bash
./uninstall.sh
```

```
[1/6] 是否停止并禁用 hysteria-server 服务？[y/n]:
[2/6] 是否删除 HY2 二进制 /usr/local/bin/hysteria？[y/n]:
[3/6] 是否删除配置目录 /etc/hysteria（含证书）？[y/n]:
[4/6] 是否删除 systemd service 文件 hysteria-server.service？[y/n]:
[5/6] 是否删除 hysteria 用户与用户组？[y/n]:
[6/6] 是否清理旧版本脚本遗留的 iptables 持久化 oneshot 服务与规则？[y/n]:
```

---

## 🚨 排障速查（一问一命令）

| 现象 | 命令 | 结论 |
|------|------|------|
| 启动后死、`journalctl` 里空 | `hysteria server --check -c /etc/hysteria/config.yaml` | 配置文件语法错，按报错行修 |
| ACME 报 Cloudflare `Code:6003 / 6111` | `grep -E "cloudflare_api_token|CF_API" /etc/hysteria/config.yaml` | 多字段（含 `CF_API_*` 或双字段）→ 只留单字段 `cloudflare_api_token: cfut_xxx`，然后 `rm -rf /etc/hysteria/acme/* && systemctl restart` |
| ACME 报 DNS-01 challenge 等不到 TXT | 去 CF Dashboard 看 `_acme-challenge.xxx` 有没有 | Token 权限缺 `Zone.DNS:Edit`，或 NS 还没切到 CF |
| 开跳跃后客户端打不通 20001–50000 | 按上面「验证端口跳跃」三条查规则 | 规则没写进去 → 要么容器没 nat 表（关跳跃），要么缺 `CAP_NET_ADMIN` |
| `systemctl status` 显示 `218/CAPABILITIES` | 看下面 sed 修 | CentOS 7 systemd 太旧，按下面 sed 一键修 |
| 自签客户端报 `certificate signed by unknown authority` | 打开 `insecure=true` 或 `skip-cert-verify: true` | 正常现象，自签就是要客户端跳校验 |

### `218/CAPABILITIES` 一键修（脚本已自动做，留给手动兜底）
```bash
sed -i 's/^AmbientCapabilities=/#&/; s/^CapabilityBoundingSet=/#&/; s/^User=hysteria/#&/; s/^Group=hysteria/#&/' /etc/systemd/system/hysteria-server.service
setcap cap_net_bind_service,cap_net_admin+ep /usr/local/bin/hysteria
systemctl daemon-reload
systemctl restart hysteria-server
```

### `masquerade.proxy.url` 带反引号
YAML 反引号**不是字符串界符**。如果是手改的配置：
```yaml
    url: https://bing.com   # ✅ 正确：裸写
    # url: `https://bing.com`  # ❌ 错误：反引号会被当成 URL 一部分
```
脚本输入阶段 `sanitize_input` 已经自动去掉首尾反引号，粘贴时直接回车就行。

---

## 📝 Changelog

- **2026-08-16**
  - 端口跳跃：只保留 HY2 官方内置 `listen: :a-b`，删除脚本手动 iptables + 持久化分支；在 README 里单开一节讲「为什么你不用写任何 iptables」
  - 所有交互确认提示符：统一为小写 `[y/n]`
  - ACME Cloudflare：只保留 libdns/cloudflare 官方支持的单字段 `cloudflare_api_token`（cfut_ 前缀），删除旧版 Global API Key 双字段分支，从源头杜绝 `CF 6003 / 6111` 报错
  - 安装交付：客户端 YAML + hysteria2:// 链接 + Clash.Meta 片段三件套自动生成，跳跃参数自动填好
  - FAQ / 排障前置：端口跳跃、Token 生成、常见报错不再藏在 FAQ，直接写在流程里醒目提醒

