# HTTP/SOCKS4/SOCKS5 代理服務器 (pproxy)
FROM python:3.12-alpine

# 安裝 pproxy（輕量級多協議代理，支援 ARM64）
RUN pip install --no-cache-dir pproxy

EXPOSE 1080

# 啟動 pproxy，監聽 1080 埠，支援 HTTP/SOCKS4/SOCKS5
CMD ["pproxy", "-l", "http+socks4+socks5://:1080", "-vv"]