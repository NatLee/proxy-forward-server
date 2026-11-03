# HTTP/SOCKS4/SOCKS5 代理服務器 (pproxy)
FROM python:3.12.16-alpine3.24

# 安裝 pproxy（輕量級多協議代理，支援 ARM64），版本固定在 requirements.txt
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# pproxy 聽的位址和埠只在這裡決定，值來自 .env（docker-compose.yml 傳進來）：
# - PROXY_BIND 沒設或留空時用 127.0.0.1，只有同一個網路裡的 SSH 通道用得到。
# - PROXY_PORT 必填，tunnel 也要用同一個值，所以不在這裡另外給預設值。
# 其他 pproxy 參數接在後面，例如 compose 加的 -vv（詳細模式要讀終端機，所以 compose 開了 tty）。
ENTRYPOINT ["/bin/sh", "-c", "exec pproxy -l \"http+socks4+socks5://${PROXY_BIND:-127.0.0.1}:${PROXY_PORT:?PROXY_PORT is not set}\" \"$@\"", "pproxy"]
