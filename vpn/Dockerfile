# OpenVPN 客戶端（docker-compose.yml 的 openvpn 服務）
# 放在 vpn/ 而不是 openvpn/：openvpn/ 是放你自己 .ovpn 的地方，不進 git。
FROM alpine:3.24.3

# build 時就裝好 OpenVPN，容器啟動時不用再上網裝套件。
# OpenVPN 的版本跟著上面的 Alpine 版本走；要更新就改 FROM（Dependabot 會開 PR）。
RUN apk add --no-cache openvpn

CMD ["openvpn", "--config", "/etc/openvpn/client.conf"]
