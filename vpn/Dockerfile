# OpenVPN 客戶端（docker-compose.yml 的 openvpn 服務；netns 也用這個映像檔）
# 放在 vpn/ 而不是 openvpn/：openvpn/ 是放你自己 .ovpn 的地方，不進 git。
FROM alpine:3.24.3

# build 時就裝好 OpenVPN，容器啟動時不用再上網裝套件。
# OpenVPN 的版本跟著上面的 Alpine 版本走；要更新就改 FROM（Dependabot 會開 PR）。
RUN apk add --no-cache openvpn

# 先清掉上次被強制結束時留下的 tun 介面，再啟動 OpenVPN（原因寫在腳本裡）
COPY start-openvpn.sh /usr/local/bin/start-openvpn
RUN chmod 755 /usr/local/bin/start-openvpn

CMD ["start-openvpn"]
