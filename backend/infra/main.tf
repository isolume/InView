resource "vultr_ssh_key" "deploy" {
  name    = "${var.instance_label}-deploy"
  ssh_key = var.ssh_public_key
}

resource "vultr_firewall_group" "backend" {
  description = "${var.instance_label} firewall"
}

resource "vultr_firewall_rule" "ssh" {
  firewall_group_id = vultr_firewall_group.backend.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = split("/", var.allowed_ssh_cidr)[0]
  subnet_size       = tonumber(split("/", var.allowed_ssh_cidr)[1])
  port              = "22"
  notes             = "SSH"
}

resource "vultr_firewall_rule" "backend_http" {
  firewall_group_id = vultr_firewall_group.backend.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = tostring(var.backend_port)
  notes             = "InView backend"
}

resource "vultr_instance" "backend" {
  label             = var.instance_label
  region            = var.region
  plan              = var.plan
  os_id             = 1743 # Ubuntu 22.04 x64 on Vultr's current catalog
  ssh_key_ids       = [vultr_ssh_key.deploy.id]
  firewall_group_id = vultr_firewall_group.backend.id
  hostname          = var.instance_label
  tags              = ["inview", "backend"]

  # The provider base64-encodes this itself; passing already-encoded text here
  # would double-encode it and cloud-init would fail to parse it on boot.
  user_data = templatefile("${path.module}/cloud-init.yaml.tpl", {
    backend_image = var.backend_image
    backend_port  = var.backend_port
  })
}
