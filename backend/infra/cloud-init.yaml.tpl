#cloud-config
package_update: true
packages:
  - docker.io

write_files:
  - path: /etc/systemd/system/inview-backend.service
    content: |
      [Unit]
      Description=InView backend
      After=docker.service network-online.target
      Requires=docker.service

      [Service]
      Restart=always
      RestartSec=2
      ExecStartPre=-/usr/bin/docker stop inview-backend
      ExecStartPre=-/usr/bin/docker rm inview-backend
      ExecStartPre=/usr/bin/docker pull ${backend_image}
      ExecStart=/usr/bin/docker run --rm --name inview-backend \
        -p ${backend_port}:3000 \
        -e INVIEW_BIND=0.0.0.0:3000 \
        -e RUST_LOG=inview_backend=info,tower_http=info \
        ${backend_image}
      ExecStop=/usr/bin/docker stop inview-backend

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl enable docker
  - systemctl start docker
  - systemctl daemon-reload
  - systemctl enable inview-backend.service
  - systemctl start inview-backend.service
