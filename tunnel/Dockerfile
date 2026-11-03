# tunnel/Dockerfile
FROM alpine:3.24.3

# 安裝 autossh 與 openssh-client
RUN apk add --no-cache autossh openssh-client

# 建立 ssh 目錄 (避免 autossh 找不到目錄報錯)
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# 預設進入點 (可以在 docker-compose 覆寫，但這裡留空方便除錯)
CMD ["/bin/sh"]