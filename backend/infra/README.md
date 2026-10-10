# Hosting the backend on Vultr

Provisions one small Vultr instance that runs `backend/Dockerfile` under systemd,
restarting it if it crashes or the instance reboots. The service keeps everything
in memory (see `../SCANS.md`), so this is sized for a demo, not durable storage:
one `vc2-1c-1gb` instance, no database, no load balancer.

## One-time setup

1. **Install Terraform** (>= 1.6) and the `vultr` CLI is not required.
2. **Get a Vultr API key**: Vultr dashboard → Account → API, enable it, copy the key.
3. **Build and push the backend image** to a registry Vultr can pull from (GitHub
   Container Registry is free for public images):

   ```sh
   cd backend
   docker login ghcr.io -u <your-username>
   docker buildx build --platform linux/amd64 -t ghcr.io/<your-username>/inview-backend:latest --push .
   ```

   Vultr's `vc2-1c-1gb` plan is x86_64. Building with a plain `docker build` on an
   Apple Silicon Mac produces an arm64-only image that the instance can't pull —
   use `buildx` with `--platform linux/amd64` as above even when building locally.

   Make the package public in GitHub (Packages → inview-backend → Package settings
   → Change visibility), or configure a pull secret — the cloud-init script below
   runs an anonymous `docker pull`.

4. **Copy the vars file** and fill it in:

   ```sh
   cd infra
   cp terraform.tfvars.example terraform.tfvars
   # edit terraform.tfvars: ssh_public_key, allowed_ssh_cidr, backend_image
   export TF_VAR_vultr_api_key="your-vultr-api-key"
   ```

   Keep the API key out of `terraform.tfvars` — the exported env var is read
   automatically by Terraform's `TF_VAR_` convention. `terraform.tfvars` and
   `*.tfstate` are git-ignored; double-check `git status` before committing.

## Deploy

```sh
cd backend/infra
terraform init
terraform plan
terraform apply
```

`terraform apply` prints `backend_url` (e.g. `http://203.0.113.10:3000`) once the
instance is up. Cloud-init takes a minute or two after the instance reports ready
to install Docker and start the service — `terraform output ssh_command` then
`systemctl status inview-backend` on the box if it's not responding yet.

Confirm it's live:

```sh
curl http://<instance_ip>:3000/health
# {"status":"ok","service":"inview-backend"}
```

## Point the app at it

Either set `INVIEW_BACKEND_URL` in `Config/Secrets.xcconfig` to the printed
`backend_url` and rebuild, or open the app's gear icon → scan processing settings
→ paste the address → Test connection → Save. No rebuild needed for the
settings-entered address; it's stored on-device and takes priority over the
build setting (see `AppConfig.backendAddress`).

## Updating the backend

Build and push a new image tag, then either:

- `terraform apply` again after bumping `backend_image` to the new tag, or
- SSH in and run `systemctl restart inview-backend` to re-pull `:latest`.

## Tearing down

```sh
terraform destroy
```

This deletes the instance, its firewall group, and the uploaded SSH key. Nothing
here provisions a database or persistent volume, so there's no data to back up
first — captured scans live only in that process's memory.

## Notes

- The backend has no authentication (see `../SCANS.md`); the firewall group only
  restricts SSH, not the backend port. Don't point this at anything beyond a
  short-lived demo without adding auth in front of it.
- `os_id = 1743` in `main.tf` is Vultr's Debian 12 image. Run
  `curl -s https://api.vultr.com/v2/os -H "Authorization: Bearer $TF_VAR_vultr_api_key" | jq '.os[] | select(.name | test("Debian"))'`
  to see current OS ids if Vultr has retired that one.
- Regions and plans: `terraform console` isn't needed — see
  https://www.vultr.com/api/#tag/region and the Instances pricing page for current
  plan ids.
