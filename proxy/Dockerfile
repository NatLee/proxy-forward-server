# HTTP/SOCKS4/SOCKS5 代理服務器 (pproxy)
FROM python:3.12.16-alpine3.24

# 安裝 pproxy（輕量級多協議代理，支援 ARM64），版本固定在 requirements.txt
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

EXPOSE 1080

# 啟動 pproxy，監聽 1080 埠，支援 HTTP/SOCKS4/SOCKS5
# 不加 -v/-vv：詳細模式會讀標準輸入，沒有 TTY 時一啟動就崩潰。
# docker-compose.yml 有開 tty，所以 -vv 加在那裡。
# 這裡聽所有介面，方便單獨 docker run -p 使用；docker-compose.yml 會改成預設只聽 127.0.0.1（PROXY_BIND）。
CMD ["pproxy", "-l", "http+socks4+socks5://:1080"]