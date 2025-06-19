#!/bin/bash

# 下载并安装 Hysteria v2
bash <(curl -fsSL https://get.hy2.sh/)

# 创建 TLS 证书
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500

# 修改证书权限
sudo chown hysteria /etc/hysteria/server.key
sudo chown hysteria /etc/hysteria/server.crt

# 清理旧配置并创建新配置文件
rm -rf /etc/hysteria/config.yaml
touch /etc/hysteria/config.yaml

# 写入配置内容（将 <Password> 替换为实际密码）
cat > /etc/hysteria/config.yaml << EOF
listen: :10000

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: 123456789  # 请将此处 <Password> 替换为你自己的连接密码

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

ignoreClientBandwidth: false
EOF

# 启用并启动服务
systemctl enable hysteria-server
systemctl start hysteria-server
systemctl status hysteria-server
