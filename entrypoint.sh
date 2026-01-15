#!/bin/bash
set -x

# ==========================================
# 🟢【硬编码配置区】
# ==========================================
export PROJECT_NAME="cloudsaver"
export TS_NAME="cs"
export APP_COMMAND="/app/docker-entrypoint.sh"
# 备份路径 (加上 /var/lib/tailscale)
export BACKUP_PATH="/app/data /app/config /var/lib/tailscale"
export APP_INTERNAL_PORT=8008
export R2_ACCESS_KEY="75e72cddecc51b32deab13873c967000"
export R2_ENDPOINT="https://6e84f688bfe062834470070a2d946be5.r2.cloudflarestorage.com"
export R2_BUCKET_NAME="hf--backups"
export JWT_SECRET="my_super_secure_password_123"
# 【核心修复】修改后端端口为 8009 (配合 Nginx upstream)
export PORT=8009
export HOST=0.0.0.0
export DataDir=/app/data
# ==========================================

# --- 1. 系统优化 ---
echo "==> [System] 正在优化 DNS..."
if echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null; then
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    echo "options timeout:2 attempts:3 rotate" >> /etc/resolv.conf
fi

# --- 2. 基础配置 ---
mkdir -p /app/data /app/config /root/.config/rclone/

# Rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
EOF

# --- 3. 生成 App 核心配置 (端口修正版) ---
echo "==> [Config] 生成 /app/config/env ..."
# 【这里也要改成 8009】
echo "PORT=8009" > /app/config/env
echo "HOST=0.0.0.0" >> /app/config/env
echo "DataDir=/app/data" >> /app/config/env

# 智能密钥逻辑
if [ -z "$JWT_SECRET" ]; then
    echo "==> [Info] 未检测到 JWT_SECRET 变量，生成随机密钥..."
    export JWT_SECRET=$(date +%s%N | md5sum | head -c 32)
else
    echo "==> [Info] 检测到固定 JWT_SECRET，已应用。"
fi
echo "JWT_SECRET=${JWT_SECRET}" >> /app/config/env
echo "SESSION_SECRET=${JWT_SECRET}" >> /app/config/env

# --- 4. 恢复数据 ---
echo "==> [Restore] 尝试恢复数据..."
rclone copy "r2:${R2_BUCKET_NAME}/${PROJECT_NAME}_backup" / --verbose || echo "跳过"

# --- 5. 链接 Nginx 日志 (保持开启，以便排错) ---
ln -sf /dev/stdout /var/log/nginx/access.log
ln -sf /dev/stderr /var/log/nginx/error.log

# --- 6. 清理与权限 ---
echo "==> [System] 清理锁文件并修复权限..."
rm -f /app/data/*.wal /app/data/*.shm /app/data/*.lock 2>/dev/null
chmod -R 777 /app/data /app/config
[ -f /app/data/cloudsaver.db ] && chmod 777 /app/data/cloudsaver.db

# --- 7. 配置 SSH (Root 登录) ---
echo "==> [SSH] 配置 Root 密码..."
if [ -n "$WEBUI_PASSWORD" ]; then
    echo "root:$WEBUI_PASSWORD" | chpasswd
    echo "Root 密码已设置为 WEBUI_PASSWORD"
else
    echo "Root 密码未设置 (使用默认值: admin123)"
    echo "root:admin123" | chpasswd
fi

echo "==> [SSH] 启动 sshd..."
/usr/sbin/sshd -D &

# --- 8. 启动 Python 保活 ---
cat > /fake_server.py <<EOF
import http.server, socketserver
class HealthCheckHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        try:
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b"Hugging Face Keep-Alive: Running with FRP")
        except: pass
    def log_message(self, format, *args): pass
if __name__ == "__main__":
    try:
        with socketserver.TCPServer(("", 7860), HealthCheckHandler) as httpd:
            httpd.serve_forever()
    except: pass
EOF
python3 /fake_server.py &

# --- 9. 启动 Tailscale (Userspace 模式) ---
echo "==> [Tailscale] 初始化..."

# 检查 path (调试用)
echo "==> [Tailscale] PATH: $PATH"
echo "==> [Tailscale] Version:"
tailscale version

# 创建状态目录 (防止部分环境报错)
mkdir -p /var/lib/tailscale

# 启动后台进程 (tun=userspace-networking 是关键，不需要 root 权限)
# 将日志输出到文件以便调试
/usr/sbin/tailscaled --tun=userspace-networking --socket=/tmp/tailscaled.sock --state=/var/lib/tailscale/tailscaled.state > /tmp/tailscaled.log 2>&1 &

# 等待 socket 文件生成 (最多等待 10 秒)
TRIES=0
while [ ! -S /tmp/tailscaled.sock ] && [ $TRIES -lt 20 ]; do
    sleep 0.5
    TRIES=$((TRIES + 1))
done

if [ ! -S /tmp/tailscaled.sock ]; then
    echo "❌ Tailscale socket 未生成，tailscaled 启动失败！"
    echo "=== Tailscale Logs ==="
    cat /tmp/tailscaled.log
    echo "======================"
else
    echo "✅ Tailscale socket 已就绪 (耗时 $((TRIES * 500))ms)"
fi

# 登录
if [ -n "$TS_AUTH_KEY" ]; then
    # 尝试 Up，如果失败则输出日志
    # 去掉绝对路径，直接使用 tailscale
    if tailscale --socket=/tmp/tailscaled.sock up --authkey="${TS_AUTH_KEY}" --hostname="${TS_NAME}" --ssh --accept-routes --advertise-exit-node; then
        # 获取 Tailscale IP 方便调试
        TS_IP=$(tailscale --socket=/tmp/tailscaled.sock ip -4)
        echo "✅ Tailscale 启动成功! IP: $TS_IP"
        # ======================================================
        (
            sleep 5
            echo "==> [Tailscale] Enabling Funnel for Port 8008..."
            # 将公网 HTTPS (443) 流量转发到本地 8008
            tailscale --socket=/tmp/tailscaled.sock funnel --bg --yes 8008
            echo "✅ Funnel enabled."
        ) &
        # ======================================================
    else
        echo "❌ Tailscale up 失败！"
        echo "=== Tailscale Logs (tailscaled) ==="
        cat /tmp/tailscaled.log
        echo "==================================="
    fi
else
    echo "⚠️ 未检测到 TS_AUTH_KEY，跳过 Tailscale 启动"
fi

# --- 10. 启动定时备份 (每12小时 + 启动后立即备份) ---
echo "==> [System] 启动定时备份 (每12小时)..."
(
  while true; do
    # 首次启动等待 60 秒后备份一次，确保 State 文件已生成
    sleep 60
    echo "==> [Backup] 执行同步..."
    for DIR in ${BACKUP_PATH}; do
        [ -d "$DIR" ] && rclone sync "$DIR" "r2:${R2_BUCKET_NAME}/${PROJECT_NAME}_backup$DIR" 2>/dev/null
    done
    # 之后每 12 小时循环
    sleep 43200
  done
) &

# --- 11. 启动主程序 ---
echo "==> [System] 启动 CloudSaver..."
${APP_COMMAND} || {
    echo "!!! 主程序崩溃 !!!"
    sleep infinity
}