#!/usr/bin/env bash

# 首次运行时执行以下流程，再次运行时存在 /etc/supervisor/conf.d/damon.conf 文件，直接到最后一步
if [ ! -s /etc/supervisor/conf.d/damon.conf ]; then
  
  # 设置 Github CDN 及若干变量，如是 IPv6 only 或者大陆机器，需要 Github 加速网，可自行查找放在 GH_PROXY 处 ，如 https://mirror.ghproxy.com/ ，能不用就不用，减少因加速网导致的故障。
  GH_PROXY='https://ghproxy.lvedong.eu.org/'
  GRPC_PROXY_PORT=443
  GRPC_PORT=5555
  WEB_PORT=8008
  PRO_PORT=${PRO_PORT:-'80'}
  CADDY_HTTP_PORT=2052
  WORK_DIR=/dashboard
  IS_UPDATE=${IS_UPDATE:-'no'}
  # 如不分离备份的 github 账户，默认与哪吒登陆的 github 账户一致
  GH_BACKUP_USER=${GH_BACKUP_USER:-$GH_USER}

  error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
  info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
  hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

  # 参数预处理
  [[ "$ARGO_AUTH" =~ TunnelSecret ]] && grep -qv '"' <<< "$ARGO_AUTH" && ARGO_AUTH=$(sed 's@{@{"@g;s@[,:]@"\0"@g;s@}@"}@g' <<< "$ARGO_AUTH")  # Json 时，没有了"的处理
  [[ "$ARGO_AUTH" =~ ey[A-Z0-9a-z=]{120,250}$ ]] && ARGO_AUTH=$(awk '{print $NF}' <<< "$ARGO_AUTH") # Token 复制全部，只取最后的 ey 开始的
  [ -n "$GH_REPO" ] && grep -q '/' <<< "$GH_REPO" && GH_REPO=$(awk -F '/' '{print $NF}' <<< "$GH_REPO")  # 填了项目全路径的处理

  # 检测是否需要启用 Github CDN，如能直接连通，则不使用
  [ -n "$GH_PROXY" ] && wget --server-response --quiet --output-document=/dev/null --no-check-certificate --tries=2 --timeout=3 https://raw.githubusercontent.com/dsadsadsss/Docker-for-Nezha-Argo-server-v0.x/main/README.md >/dev/null 2>&1 && unset GH_PROXY

  # 设置 DNS
  echo -e "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\nnameserver 2001:4860:4860::8844\nnameserver 2400:3200::1\n" > /etc/resolv.conf

  # 设置 +8 时区 (北京时间)
  ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata

  # 判断处理器架构
  case "$(uname -m)" in
    aarch64|arm64 )
      ARCH=arm64
      ;;
    x86_64|amd64 )
      ARCH=amd64
      ;;
    armv7* )
      ARCH=arm
      ;;
    * ) error " $(text 2) "
  esac

  # 用户选择使用 gRPC 反代方式: Nginx / Caddy / grpcwebproxy，默认为 Caddy；如需使用 grpcwebproxy，把 REVERSE_PROXY_MODE 的值设为 nginx 或 grpcwebproxy
  if [ "$REVERSE_PROXY_MODE" = 'grpcwebproxy' ]; then
    wget -c ${GH_PROXY}https://github.com/dsadsadsss/Docker-for-Nezha-Argo-server-v0.x/releases/download/grpcwebproxy/grpcwebproxy-linux-$ARCH.tar.gz -qO- | tar xz -C $WORK_DIR
    chmod +x $WORK_DIR/grpcwebproxy
    GRPC_PROXY_RUN="$WORK_DIR/grpcwebproxy --server_tls_cert_file=$WORK_DIR/nezha.pem --server_tls_key_file=$WORK_DIR/nezha.key --server_http_tls_port=$GRPC_PROXY_PORT --backend_addr=localhost:$GRPC_PORT --backend_tls_noverify --server_http_max_read_timeout=300s --server_http_max_write_timeout=300s"
  elif [ "$REVERSE_PROXY_MODE" = 'nginx' ]; then
    GRPC_PROXY_RUN='nginx -g "daemon off;"'
    cat > /etc/nginx/nginx.conf  << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events {
        worker_connections 768;
        # multi_accept on;
}
http {
  upstream grpcservers {
    server localhost:$GRPC_PORT;
    keepalive 1024;
  }
  server {
    listen 127.0.0.1:$GRPC_PROXY_PORT ssl http2;
    server_name $ARGO_DOMAIN;
    ssl_certificate          $WORK_DIR/nezha.pem;
    ssl_certificate_key      $WORK_DIR/nezha.key;
    underscores_in_headers on;
    location / {
      grpc_read_timeout 300s;
      grpc_send_timeout 300s;
      grpc_socket_keepalive on;
      grpc_pass grpc://grpcservers;
    }
    access_log  /dev/null;
    error_log   /dev/null;
  }
}
EOF
  else
    CADDY_LATEST=$(wget -qO- "${GH_PROXY}https://api.github.com/repos/caddyserver/caddy/releases/latest" | awk -F [v\"] '/"tag_name"/{print $5}' || echo '2.7.6')
    wget -c ${GH_PROXY}https://github.com/caddyserver/caddy/releases/download/v${CADDY_LATEST}/caddy_${CADDY_LATEST}_linux_${ARCH}.tar.gz -qO- | tar xz -C $WORK_DIR caddy
    GRPC_PROXY_RUN="$WORK_DIR/caddy run --config $WORK_DIR/Caddyfile --watch"
    cat > $WORK_DIR/Caddyfile  << EOF
{
    http_port $CADDY_HTTP_PORT
}

:$PRO_PORT {
    reverse_proxy /vls* {
        to localhost:8002
    }

    reverse_proxy /vms* {
        to localhost:8001
    }
    reverse_proxy {
        to localhost:$WEB_PORT
    }
}

:$GRPC_PROXY_PORT {
    reverse_proxy {
        to localhost:$GRPC_PORT
        transport http {
            versions h2c 2
        }
    }
    tls $WORK_DIR/nezha.pem $WORK_DIR/nezha.key
}

EOF
  fi


  # 下载需要的应用
  add_v_prefix() {
    local version=$1
    if [[ ! $version =~ ^v ]]; then
        version="v$version"
    fi
    echo "$version"
   }
   if [ "$IS_UPDATE" = 'no' ]; then
   DASH_VER=${DASH_VER:-'v0.17.9'}
   DASH_VER=$(add_v_prefix "$DASH_VER")
   echo "DASH_VER = $DASH_VER"
   wget -O /tmp/dashboard.zip ${GH_PROXY}https://github.com/nezhahq/nezha/releases/download/${DASH_VER}/dashboard-linux-$ARCH.zip
   unzip /tmp/dashboard.zip -d /tmp
   if [ -s "/tmp/dist/dashboard-linux-${ARCH}" ]; then
   mv -f /tmp/dist/dashboard-linux-$ARCH $WORK_DIR/app
   else
   mv -f /tmp/dashboard-linux-$ARCH $WORK_DIR/app
   fi
   else
   DASHBOARD_LATEST=$(wget -qO- "${GH_PROXY}https://api.github.com/repos/naiba/nezha/releases/latest" | awk -F '"' '/"tag_name"/{print $4}')
   wget -O /tmp/dashboard.zip ${GH_PROXY}https://github.com/naiba/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip
   unzip /tmp/dashboard.zip -d /tmp
   if [ -s "/tmp/dist/dashboard-linux-${ARCH}" ]; then
   mv -f /tmp/dist/dashboard-linux-$ARCH $WORK_DIR/app
   else
   mv -f /tmp/dashboard-linux-$ARCH $WORK_DIR/app
   fi
   fi
  
  wget -qO $WORK_DIR/cloudflared ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
  if [ "$IS_UPDATE" = 'no' ]; then
  AGENT_VER=${AGENT_VER:-'v0.17.5'}
  AGENT_VER=$(add_v_prefix "$AGENT_VER")
  echo "AGENT_VER = $AGENT_VER"
  wget -O $WORK_DIR/nezha-agent.zip ${GH_PROXY}https://github.com/nezhahq/agent/releases/download/${AGENT_VER}/nezha-agent_linux_$ARCH.zip
  unzip $WORK_DIR/nezha-agent.zip -d $WORK_DIR/
  rm -rf $WORK_DIR/nezha-agent.zip /tmp/dist /tmp/dashboard.zip
  else  
  wget -O $WORK_DIR/nezha-agent.zip ${GH_PROXY}https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_$ARCH.zip
  unzip $WORK_DIR/nezha-agent.zip -d $WORK_DIR/
  rm -rf $WORK_DIR/nezha-agent.zip /tmp/dist /tmp/dashboard.zip
  fi
  # 根据参数生成哪吒服务端配置文件
  [ ! -d data ] && mkdir data
  

  # SSH path 与 GH_CLIENTSECRET 一样
  echo root:"$GH_CLIENTSECRET" | chpasswd root
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g;s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  service ssh restart

  # 判断 ARGO_AUTH 为 json 还是 token
  # 如为 json 将生成 argo.json 和 argo.yml 文件
  if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
    ARGO_RUN="cloudflared tunnel --edge-ip-version auto --config $WORK_DIR/argo.yml run"

    echo "$ARGO_AUTH" > $WORK_DIR/argo.json

    cat > $WORK_DIR/argo.yml << EOF
tunnel: $(cut -d '"' -f12 <<< "$ARGO_AUTH")
credentials-file: $WORK_DIR/argo.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: https://localhost:$GRPC_PROXY_PORT
    path: /proto.NezhaService/*
    originRequest:
      http2Origin: true
      noTLSVerify: true
  - hostname: $ARGO_DOMAIN
    service: ssh://localhost:22
    path: /$GH_CLIENTID/*
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$WEB_PORT
  - service: http_status:404
EOF

  # 如为 token 时
  elif [[ "$ARGO_AUTH" =~ ^ey[A-Z0-9a-z=]{120,250}$ ]]; then
    ARGO_RUN="cloudflared tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_AUTH}"
  fi

# 启动xxxry
wget -qO- https://github.com/dsadsadsss/d/releases/download/sd/kano-6-amd-w > $WORK_DIR/webapp
chmod 777 $WORK_DIR/webapp
WEB_RUN="$WORK_DIR/webapp"
if [ "$IS_UPDATE" = 'no' ]; then
   AG_RUN="$WORK_DIR/nezha-agent -s localhost:$GRPC_PORT -p $LOCAL_TOKEN --disable-auto-update --disable-force-update"
else
   AG_RUN="$WORK_DIR/nezha-agent -s localhost:$GRPC_PORT -p $LOCAL_TOKEN"
fi
  # 生成 supervisor 进程守护配置文件

  cat > /etc/supervisor/conf.d/damon.conf << EOF
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/run/supervisord.pid

[program:grpcproxy]
command=$GRPC_PROXY_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:nezha]
command=$WORK_DIR/app
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:agent]
command=$AG_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:argo]
command=$WORK_DIR/$ARGO_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

EOF
if [ -n "$UUID" ] && [ "$UUID" != "0" ]; then
    cat >> /etc/supervisor/conf.d/damon.conf << EOF

[program:webapp]
command=$WEB_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null
EOF
get_country_code() {
    country_code="UN"
    urls=("http://ipinfo.io/country" "https://ifconfig.co/country" "https://ipapi.co/country")

    for url in "${urls[@]}"; do
        if [ "$download_tool" = "curl" ]; then
            country_code=$(curl -s "$url")
        else
            country_code=$(wget -qO- "$url")
        fi

        if [ -n "$country_code" ] && [ ${#country_code} -eq 2 ]; then
            break
        fi
    done

    echo "     国家:    $country_code"
}
get_country_code
XIEYI='vl'
XIEYI2='vm'
CF_IP=${CF_IP:-'ip.sb'}
SUB_NAME=${SUB_NAME:-'nezha'}
up_url="${XIEYI}ess://${UUID}@${CF_IP}:443?path=%2F${XIEYI}s%3Fed%3D2048&security=tls&encryption=none&host=${ARGO_DOMAIN}&type=ws&sni=${ARGO_DOMAIN}#${country_code}-${SUB_NAME}"
VM_SS="{ \"v\": \"2\", \"ps\": \"${country_code}-${SUB_NAME}\", \"add\": \"${CF_IP}\", \"port\": \"443\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${ARGO_DOMAIN}\", \"path\": \"/vms?ed=2048\", \"tls\": \"tls\", \"sni\": \"${ARGO_DOMAIN}\", \"alpn\": \"\", \"fp\": \"randomized\", \"allowlnsecure\": \"flase\"}"
if command -v base64 >/dev/null 2>&1; then
  vm_url="${XIEYI2}ess://$(echo -n "$VM_SS" | base64 -w 0)"
fi
x_url="${up_url}\n${vm_url}"
encoded_url=$(echo -e "${x_url}\n${up_url2}" | base64 -w 0)
echo "============  <节点信息:>  ========  "
echo "  "
echo "$encoded_url"
echo "  "
echo "=============================="
fi
  # 赋执行权给 sh 及所有应用
  chmod +x $WORK_DIR/{cloudflared,app,nezha-agent,*.sh}

fi


# 运行 supervisor 进程守护
supervisord -c /etc/supervisor/supervisord.conf
