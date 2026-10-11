#cloud-config
package_update: true
packages:
  - docker.io
  - caddy

write_files:
  - path: /etc/inview/backend.env
    permissions: '0600'
    content: |
      INVIEW_API_TOKEN=${api_token}
  - path: /etc/caddy/Caddyfile
    content: |
      ${backend_domain} {
        reverse_proxy 127.0.0.1:${backend_port}
      }
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
  - systemctl enable caddy
  - systemctl restart caddy
