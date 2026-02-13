# Proxy Forward Server

這是一個基於 Docker 的代理轉發伺服器，結合 OpenVPN、SSH 反向通道與 pproxy，讓你能透過 SSH 轉發流量並封裝在 VPN 通道內。

## 架構

1. **openvpn**: 建立 VPN 連線 (tun0)。
2. **proxy (pproxy)**: 輕量級 HTTP/SOCKS4/SOCKS5 代理，監聽容器內的 `1080` 埠。流量透過 OpenVPN 出去。
3. **tunnel (ssh)**: 建立 SSH 反向通道，將遠端伺服器的埠口 (預設 `2080`) 轉發到本地的 `1080` Proxy。

## 使用方式

### 1. 產生 SSH Key 並部署到遠端主機

首先產生一組專用的 SSH Key（不要設密碼，因為 autossh 需要自動登入）：

```bash
# 產生金鑰 (預設路徑 keys/key-to-aws.pem)
ssh-keygen -t ed25519 -f ./keys/key-to-aws.pem -N ""
```

接著將公鑰 (`.pub`) 內容部署到 **遠端伺服器 (Remote Host)** 的 `~/.ssh/authorized_keys` 中：

```bash
# 查看公鑰內容
cat ./keys/key-to-aws.pem.pub
# 複製輸出內容，貼到遠端主機的 ~/.ssh/authorized_keys
```

### 2. 設定環境變數

複製範例設定檔並填入你的資訊：

```bash
cp .env.example .env
```

編輯 `.env`：
- `REMOTE_HOST`: 遠端 SSH 伺服器 IP
- `REMOTE_USER`: SSH 使用者
- `SSH_KEY_PATH`: SSH 私鑰路徑 (需放在專案目錄下)
- `REMOTE_PORT`: 遠端轉發的埠口 (預設 2080)

### 3. 準備金鑰與設定

- **SSH Key**: 將私鑰放在 `keys/` 目錄 (或 `.env` 指定的路徑)
- **OpenVPN Config**: 將 `.ovpn` 檔案放在 `openvpn/client.ovpn`

### 4. 啟動服務

```bash
docker compose up -d --build
```

### 5. 在遠端伺服器使用 Proxy

在遠端伺服器 (REMOTE_HOST) 上，現在可以透過本地的 `REMOTE_PORT` (預設 2080) 使用代理：

```bash
# SOCKS5
curl -x socks5://127.0.0.1:2080 http://httpbin.org/ip

# HTTP
curl -x http://127.0.0.1:2080 http://httpbin.org/ip
```

設定為系統 Proxy：
```bash
export http_proxy=http://127.0.0.1:2080
export https_proxy=http://127.0.0.1:2080
```
