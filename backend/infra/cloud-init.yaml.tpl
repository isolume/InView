#cloud-config
package_update: true
# Vultr os_id 1743 is Ubuntu 22.04, whose repositories carry no caddy package, so Caddy is
# installed as the official static binary in runcmd with its standard systemd unit.
packages:
  - docker.io
  - curl

write_files:
  - path: /etc/inview/backend.env
    permissions: '0600'
    content: |
      INVIEW_API_TOKEN=${api_token}
  # Caddy serves HTTPS for backend_domain, or for <ip-with-dashes>.sslip.io when no domain was
  # given. The instance learns its own address only after boot, so the Caddyfile is written in runcmd.
  - path: /usr/local/sbin/inview-caddyfile
    permissions: '0755'
    content: |
      #!/bin/sh
      set -eu
      domain="${backend_domain}"
      if [ -z "$domain" ]; then
        ip="$(curl -fsS --max-time 20 https://api.ipify.org 2>/dev/null \
          || curl -fsS --max-time 20 https://ifconfig.me 2>/dev/null \
          || ip -4 route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')"
        domain="$(printf '%s' "$ip" | tr . -).sslip.io"
      fi
      printf '%s {\n  reverse_proxy 127.0.0.1:${backend_port}\n}\n' "$domain" > /etc/caddy/Caddyfile
      printf 'INVIEW_BACKEND_URL=https://%s\n' "$domain" > /etc/inview/backend-url
  - path: /etc/systemd/system/caddy.service
    content: |
      [Unit]
      Description=Caddy
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=notify
      User=caddy
      Group=caddy
      ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
      ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
      TimeoutStopSec=5s
      LimitNOFILE=1048576
      PrivateTmp=true
      ProtectSystem=full
      AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/inview-backend.service
    content: |
      [Unit]
      Description=InView backend
      After=docker.service network-online.target
      Requires=docker.service

      [Service]
      Restart=always
      RestartSec=2
      TimeoutStopSec=30
      ExecStartPre=-/usr/bin/docker stop inview-backend
      ExecStartPre=-/usr/bin/docker rm inview-backend
      ExecStartPre=/usr/bin/docker pull ${backend_image}
      ExecStart=/usr/bin/docker run --rm --name inview-backend \
        -p 127.0.0.1:${backend_port}:3000 \
        --env-file /etc/inview/backend.env \
        --mount type=bind,source=/var/lib/inview,target=/data \
        --cap-drop ALL --security-opt no-new-privileges \
        -e INVIEW_BIND=0.0.0.0:3000 \
        -e INVIEW_SCAN_DIR=/data/scans \
        -e INVIEW_STREAM_DIR=/data/streams \
        -e RUST_LOG=inview_backend=info,tower_http=info \
        ${backend_image}
      ExecStop=/usr/bin/docker stop inview-backend

      [Install]
      WantedBy=multi-user.target

runcmd:
  - install -d -o 10001 -g 10001 -m 0700 /var/lib/inview
  - systemctl enable docker
  - systemctl start docker
  - systemctl daemon-reload
  - systemctl enable inview-backend.service
  - systemctl start inview-backend.service
  - curl -fsSL -o /usr/local/bin/caddy "https://caddyserver.com/api/download?os=linux&arch=amd64"
  - chmod 755 /usr/local/bin/caddy
  - groupadd --system caddy
  - useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
  - mkdir -p /etc/caddy
  # Vultr's Ubuntu image ships ufw enabled with only SSH open; the Vultr firewall group is not enough.
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - /usr/local/sbin/inview-caddyfile
  - systemctl daemon-reload
  - systemctl enable --now caddy
