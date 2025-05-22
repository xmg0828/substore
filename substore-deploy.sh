#!/bin/bash

# Sub-Store 一键部署脚本
# 自动配置 Nginx + SSL + Docker 环境

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印彩色信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 生成随机 API 路径
generate_api_path() {
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local path=""
    for i in {1..32}; do
        path+="${chars:RANDOM%${#chars}:1}"
    done
    echo "/api-$path"
}

# 用户输入配置
echo "=================================================="
echo "       Sub-Store 一键部署脚本"
echo "=================================================="
echo

# 获取域名
while true; do
    read -p "请输入您的域名 (例: example.com): " DOMAIN
    if [[ -n "$DOMAIN" && "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
        break
    else
        print_error "请输入有效的域名格式"
    fi
done

# 获取端口
read -p "请输入服务端口 (默认: 3001): " PORT
PORT=${PORT:-3001}

# 获取 API 路径
read -p "请输入 API 路径 (留空自动生成): " API_PATH
if [[ -z "$API_PATH" ]]; then
    API_PATH=$(generate_api_path)
    print_info "自动生成 API 路径: $API_PATH"
fi

# 确保 API 路径以 / 开头
if [[ ! "$API_PATH" =~ ^/ ]]; then
    API_PATH="/$API_PATH"
fi

# 配置变量
API_URL="https://$DOMAIN$API_PATH"
DATA_DIR="/root/sub-store-data"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN"

echo
print_info "配置信息:"
echo "域名: $DOMAIN"
echo "端口: $PORT"
echo "API路径: $API_PATH"
echo "API地址: $API_URL"
echo "数据目录: $DATA_DIR"
echo

read -p "确认以上配置? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_warning "用户取消部署"
    exit 0
fi

echo
print_info "开始部署..."

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   print_error "请使用 root 用户运行此脚本"
   exit 1
fi

# 1. 安装环境
print_info "1. 更新系统并安装必要软件..."
apt update && apt upgrade -y
apt install -y nginx certbot python3-certbot-nginx docker.io ufw

# 2. 启动服务
print_info "2. 启动 Docker 和 Nginx 服务..."
systemctl enable docker
systemctl start docker
systemctl enable nginx
systemctl start nginx

# 3. 配置防火墙
print_info "3. 配置防火墙..."
ufw --force enable
ufw allow ssh
ufw allow 80
ufw allow 443
ufw allow $PORT

# 4. 创建初始 HTTP 配置
print_info "4. 创建 Nginx HTTP 配置..."
cat > "$NGINX_CONF" << NGINX
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # 健康检查
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
NGINX

# 创建软链接
[ -f "$NGINX_LINK" ] || ln -s "$NGINX_CONF" "$NGINX_LINK"

# 删除默认配置
if [ -f "/etc/nginx/sites-enabled/default" ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# 测试配置并重载
nginx -t && systemctl reload nginx

# 5. 申请 SSL 证书
print_info "5. 申请 SSL 证书..."
print_warning "请确保域名 $DOMAIN 已正确解析到此服务器 IP"
read -p "是否继续申请证书? (y/N): " ssl_confirm

if [[ "$ssl_confirm" =~ ^[Yy]$ ]]; then
    # 获取邮箱
    read -p "请输入邮箱地址 (用于证书通知): " EMAIL
    if [[ -n "$EMAIL" ]]; then
        certbot --nginx --agree-tos --email "$EMAIL" -d "$DOMAIN" --non-interactive
    else
        certbot --nginx --agree-tos --register-unsafely-without-email -d "$DOMAIN" --non-interactive
    fi
    
    if [[ $? -eq 0 ]]; then
        print_success "SSL 证书申请成功"
        
        # 6. 更新 HTTPS 配置
        print_info "6. 更新 HTTPS 配置..."
        cat > "$NGINX_CONF" << NGINX
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # SSL 优化配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # 健康检查
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
NGINX
        nginx -t && systemctl reload nginx
    else
        print_error "SSL 证书申请失败，继续使用 HTTP 配置"
    fi
else
    print_warning "跳过 SSL 证书申请，使用 HTTP 配置"
fi

# 7. 创建数据目录
print_info "7. 创建数据目录..."
mkdir -p "$DATA_DIR"

# 8. 启动 Docker 容器
print_info "8. 启动 Sub-Store Docker 容器..."
docker stop sub-store 2>/dev/null
docker rm sub-store 2>/dev/null

# 拉取最新镜像
docker pull xream/sub-store

docker run -it -d --restart=always \
  --name sub-store \
  -e "SUB_STORE_CRON=0 0 * * *" \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=$API_PATH" \
  -e "API_URL=$API_URL" \
  -p "$PORT:$PORT" \
  -v "$DATA_DIR:/opt/app/data" \
  xream/sub-store

# 检查容器状态
sleep 5
if docker ps | grep -q sub-store; then
    print_success "Sub-Store 容器启动成功"
else
    print_error "Sub-Store 容器启动失败"
    print_info "查看容器日志:"
    docker logs sub-store
    exit 1
fi

# 9. 设置自动证书续期
if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    print_info "9. 设置 SSL 证书自动续期..."
    cat > /etc/cron.daily/cert_renew << CRON
#!/bin/bash
certbot renew --quiet --deploy-hook "systemctl reload nginx"
CRON
    chmod +x /etc/cron.daily/cert_renew
fi

# 10. 设置自动更新容器
print_info "10. 设置 Docker 容器自动更新..."
cat > /etc/cron.d/substore_update << CRON
# Sub-Store 自动更新 (每3天凌晨3点)
0 3 */3 * * root /usr/bin/docker pull xream/sub-store && \\
/usr/bin/docker stop sub-store && \\
/usr/bin/docker rm sub-store && \\
/usr/bin/docker run -it -d --restart=always \\
--name sub-store \\
-e "SUB_STORE_CRON=0 0 * * *" \\
-e "SUB_STORE_FRONTEND_BACKEND_PATH=$API_PATH" \\
-e "API_URL=$API_URL" \\
-p $PORT:$PORT \\
-v $DATA_DIR:/opt/app/data \\
xream/sub-store > /var/log/substore_update.log 2>&1
CRON

systemctl restart cron

# 11. 创建管理脚本
print_info "11. 创建管理脚本..."
cat > /root/substore_manage.sh << 'MANAGE'
#!/bin/bash

case "$1" in
    start)
        docker start sub-store
        echo "Sub-Store 已启动"
        ;;
    stop)
        docker stop sub-store
        echo "Sub-Store 已停止"
        ;;
    restart)
        docker restart sub-store
        echo "Sub-Store 已重启"
        ;;
    status)
        docker ps | grep sub-store
        ;;
    logs)
        docker logs -f sub-store
        ;;
    update)
        docker pull xream/sub-store
        docker stop sub-store
        docker rm sub-store
        # 重新运行容器的命令需要根据实际配置调整
        echo "请手动重新运行容器或重新执行部署脚本"
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status|logs|update}"
        exit 1
        ;;
esac
MANAGE

chmod +x /root/substore_manage.sh

# 完成部署
echo
echo "=================================================="
print_success "🎉 Sub-Store 部署完成！"
echo "=================================================="
echo
print_info "访问信息:"
if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    echo "🌐 管理面板: https://$DOMAIN"
    echo "📱 订阅地址: https://$DOMAIN/subs?api=$API_URL"
else
    echo "🌐 管理面板: http://$DOMAIN"
    echo "📱 订阅地址: http://$DOMAIN/subs?api=$API_URL"
fi
echo
print_info "管理命令:"
echo "启动服务: /root/substore_manage.sh start"
echo "停止服务: /root/substore_manage.sh stop"
echo "重启服务: /root/substore_manage.sh restart"
echo "查看状态: /root/substore_manage.sh status"
echo "查看日志: /root/substore_manage.sh logs"
echo
print_info "重要文件位置:"
echo "数据目录: $DATA_DIR"
echo "Nginx配置: $NGINX_CONF"
echo "管理脚本: /root/substore_manage.sh"
echo
print_warning "请妥善保管您的 API 路径: $API_PATH"
echo "=================================================="
