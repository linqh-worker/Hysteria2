markdown

# Hysteria v2 后端一键安装与配置教程

![Hysteria 2](logo.svg)

## 1. 前置条件

- **服务器要求**：一台运行 Linux 的服务器（推荐 Ubuntu、Debian 或 CentOS）
- **权限要求**：拥有 `sudo` 权限
- **网络要求**：服务器已联网，且已开放 UDP 端口 `10000`（可根据需求更改）

---

## 2. 直接部署 （_2.x 后续步骤仅供参考，可跳过_）

### 2.1 获取仓库地址

```
https://github.com/linqh-worker/Hysteria2.git hysteria && cd hysteria
```

### 2.2 编辑 Shell 文件修改端口以及密码

#### 2.2.1 使用 Vim 编辑 `install.sh` 脚本中的配置内容：

```bash
vim install.sh

listen: :10010                  # <listen>：将此处端口设置为你想要监听的端口

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: da0df8052           # <password>：将此处替换为你自己的连接密码

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

ignoreClientBandwidth: false

```

- ✅ 修改完成后保存并退出 Vim（使用 Esc → 输入 :wq → 回车），即可准备执行脚本。

#### 2.2.2 赋予执行权限并运行安装脚本：

```bash
chmod +x install.sh
bash install.sh
```

- ✅ 安装完成后，您的客户端连接链接格式如下

```
hysteria2://密码@IP:端口?insecure=1
```

- 请将其中的 密码、IP 和 端口 替换为您在 install.sh 中配置的内容，例如：

```
hysteria2://a970a7e3b@107.172.132.243:10101?insecure=1
```

- ✅ 该链接可直接用于支持 Hysteria v2 的客户端进行一键导入连接。

## 3. 安装与配置步骤

### 3.1 下载并安装 Hysteria v2

通过以下命令从官方脚本安装 Hysteria v2：

```bash
bash <(curl -fsSL https://get.hy2.sh/)
```

### 3.2 生成自签 TLS 证书

使用 OpenSSL 生成自签 TLS 证书：

```bash
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500
```

### 3.3 修改证书权限

确保证书文件具有正确的权限：

```bash
sudo chown hysteria /etc/hysteria/server.key
sudo chown hysteria /etc/hysteria/server.crt
```

### 3.4 创建并写入配置文件

#### 3.4.1 清理旧配置文件并创建新文件

```bash
rm -rf /etc/hysteria/config.yaml
touch /etc/hysteria/config.yaml
```

#### 3.4.2 写入基本配置文件

基本配置

使用以下命令写入基本配置内容（请将 listen 字段的端口和 password 字段替换为您自定义的值）：

```bash
cat > /etc/hysteria/config.yaml << EOF
listen: :10000       # <listen>：将此处端口设置为你想要监听的端口

tls:
cert: /etc/hysteria/server.crt
key: /etc/hysteria/server.key

auth:
type: password
password: 123456789 # 请替换为您的自定义密码

masquerade:
type: proxy
proxy:
url: https://bing.com
rewriteHost: true

ignoreClientBandwidth: false
EOF
```

#### 3.4.3 出站

为了实现 IPv4 优先与分流，我们还可以单独设置出站，目前 Hysteria 2 只支持 direct socks5 http 出站，其中第一个出站为默认出站，因此建议将 direct 放在第一个

在 direct 出站中，可以通过 mode 选项来指定 IPv4 与 IPv6 的优先级

- 提示

- 直连的 IPv4 和 IPv6 优先级由 mode 设置决定，与系统设置的优先级无关

```bash
outbounds:
  - name: DIRECT
    type: direct
    direct:
      mode: 46
  - name: WARP
    type: socks5
    socks5:
      addr: 127.0.0.1:40000
```

#### 3.4.4 ACL

ACL 类似路由规则，按照 outbound(address) 的格式就可以实现分流到指定出站

```bash
acl:
  inline:
    - warp(geosite:reddit)
    - reject(geoip:cn)
```

## 4. 管理 Hysteria 服务

### 4.1 启用并启动服务

启用并启动 Hysteria 服务，并检查其状态：

```bash
systemctl enable hysteria-server
systemctl start hysteria-server
systemctl status hysteria-server
```

### 4.2 常用命令

- 设置开机启动 `systemctl enable hysteria-server`
- 启动 Hysteria 2 `systemctl start hysteria-server`
- 关闭 Hysteria 2 `systemctl stop hysteria-server`
- 重启 Hysteria 2 `systemctl restart hysteria-server`
- 检查运行状况 `systemctl status hysteria-server`

## 注意事项

- 在执行上述步骤前，请确保服务器的防火墙已开放 UDP 端口 `10000`（或您在配置文件中自定义的端口）。
- 配置文件中的 `password` 字段必须替换为安全的自定义密码，避免使用默认值以确保安全性。
- 自签 TLS 证书的有效期设置为 36500 天（约 100 年），可根据实际需求调整有效期。
