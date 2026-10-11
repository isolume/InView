# Hosting the backend on Vultr

Terraform provisions an Ubuntu 22.04 instance (Vultr os_id 1743) with Docker, a systemd backend service,
and Caddy (official static binary) as the HTTPS reverse proxy. Only SSH, HTTP redirects/certificate
renewal, and HTTPS are exposed. The backend port binds to loopback.

Source scans, derived analyses, graphs, and continuous streams are stored under
`/var/lib/inview`, mounted at `/data` in the container. Container restarts and
image updates retain those files. Building-map endpoints require a separately
configured PostgreSQL database; this deployment does not provision one.
Local furniture recognition is not bundled into the backend image.

## Setup

1. Install Terraform >= 1.6 and Docker with Buildx.
2. Obtain a Vultr API key and a DNS hostname you control.
3. Build and push an image that the instance can pull:

   ```sh
   cd backend
   docker login ghcr.io -u <your-username>
   docker buildx build --platform linux/amd64 -t ghcr.io/<your-username>/inview-backend:<tag> --push .
   ```

   Use a public image or configure registry credentials on the instance. The
   default Vultr plan is x86_64, including when the build runs on Apple Silicon.

4. Copy `terraform.tfvars.example` to `terraform.tfvars`. Set `ssh_public_key`,
   `allowed_ssh_cidr`, and `backend_image`. Prefer a fixed image tag or digest.
   The SSH CIDR must restrict access to your network. Set `backend_domain` if you
   own a hostname; leave it empty and the instance serves HTTPS at
   `https://<ip-with-dashes>.sslip.io` (a public wildcard DNS service that
   resolves to the instance), which needs no DNS record.
5. Supply the secrets through the environment:

   ```sh
   export TF_VAR_vultr_api_key="your-vultr-api-key"
   export TF_VAR_api_token="$(openssl rand -hex 32)"
   ```

   Save the generated backend token in your password manager. Terraform marks
   it sensitive, but it is still present in state and instance user data. Keep
   state private. Local vars and state files are ignored; check `jj status`
   before committing.

## Deploy

```sh
cd backend/infra
terraform init
terraform plan
terraform apply
terraform output instance_ip
```

With your own `backend_domain`, point its DNS A record at `instance_ip`; Caddy
obtains a certificate once DNS resolves to the instance. Without one, `terraform
output backend_url` prints the sslip.io address, ready a minute or two after boot. Cloud-init installs packages and starts both
services; inspect `systemctl status inview-backend caddy` over SSH if needed.
See [Caddy's HTTPS setup](https://caddyserver.com/docs/quick-starts/reverse-proxy)
for DNS and certificate requirements.

Verify with the same backend token:

```sh
curl -H "Authorization: Bearer $TF_VAR_api_token" "$(terraform output -raw backend_url)/health"
```

The backend refuses to start on a public bind without a token, and the app only
sends its token over HTTPS, so a plain `http://<ip>:3000` deployment cannot
receive scans from the phone.

In the app's **Scan processing** settings, enter the HTTPS address and access
token, then test and save. The token is stored in the phone's Keychain.

## Update and backup

Cloud-init runs only on initial boot. To update an existing instance, copy the
new image reference into `/etc/systemd/system/inview-backend.service`, run
`systemctl daemon-reload`, then `systemctl restart inview-backend`. Updating
Terraform user data alone does not rerun provisioning. To rotate the token,
update `/etc/inview/backend.env` and restart the service.

Back up `/var/lib/inview` before replacing or destroying the instance. If a
PostgreSQL database is configured, back it up together with the scan directory.
`terraform destroy` deletes the instance and its local data. This setup has no
separate persistent volume or automated backups.
