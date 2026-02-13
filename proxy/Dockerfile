# HTTP 代理服務器 (tinyproxy)
FROM alpine:latest

# 安裝 tinyproxy (輕量級 HTTP 代理，支援 ARM64)
RUN apk add --no-cache tinyproxy

# 創建設定檔
RUN echo "User root" > /etc/tinyproxy/tinyproxy.conf && \
    echo "Group root" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "Port 1080" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "Listen 0.0.0.0" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "Allow 0.0.0.0/0" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "Timeout 30" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "DefaultErrorFile \"/usr/share/tinyproxy/default.html\"" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "StatFile \"/usr/share/tinyproxy/stats.html\"" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "Logfile \"/var/log/tinyproxy/tinyproxy.log\"" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "LogLevel Connect" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "PidFile \"/var/run/tinyproxy/tinyproxy.pid\"" >> /etc/tinyproxy/tinyproxy.conf && \
    echo "ViaProxyName \"tinyproxy\"" >> /etc/tinyproxy/tinyproxy.conf && \
    mkdir -p /var/log/tinyproxy /var/run/tinyproxy

EXPOSE 1080

# 啟動 tinyproxy
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]