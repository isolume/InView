variable "vultr_api_key" {
  description = "Vultr API key. Set via TF_VAR_vultr_api_key or terraform.tfvars (git-ignored)."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Vultr region id, e.g. \"ewr\" (New Jersey), \"lax\" (Los Angeles), \"sjc\" (Silicon Valley)."
  type        = string
  default     = "ewr"
}

variable "plan" {
  description = "Vultr instance plan. Size for the scan geometry and processing workload."
  type        = string
  default     = "vc2-1c-1gb"
}

variable "ssh_public_key" {
  description = "Your public key (e.g. contents of ~/.ssh/id_ed25519.pub), for SSH access to the instance."
  type        = string
}

variable "backend_port" {
  description = "Loopback port for the backend, behind Caddy HTTPS."
  type        = number
  default     = 3000
  validation {
    condition     = var.backend_port >= 1024 && var.backend_port <= 65535 && floor(var.backend_port) == var.backend_port
    error_message = "backend_port must be an integer between 1024 and 65535."
  }
}

variable "backend_domain" {
  description = "DNS hostname pointed at the instance, used for automatic HTTPS. Leave empty to use <instance-ip>.sslip.io, a public DNS name that resolves to the instance without any records of your own."
  type        = string
  default     = ""
  validation {
    condition     = var.backend_domain == "" || can(regex("^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}$", var.backend_domain))
    error_message = "backend_domain must be empty or a DNS hostname without a scheme, port, or path."
  }
}

variable "api_token" {
  description = "Backend bearer token. Generate with openssl rand -hex 32 and supply via TF_VAR_api_token."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{32,}$", var.api_token))
    error_message = "api_token must contain at least 32 letters, digits, underscores, or hyphens."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into the instance. Restrict this to your own IP (e.g. \"203.0.113.4/32\") instead of leaving it open."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.allowed_ssh_cidr)) && var.allowed_ssh_cidr != "0.0.0.0/0"
    error_message = "allowed_ssh_cidr must restrict SSH to a valid IPv4 CIDR."
  }
}

variable "backend_image" {
  description = "Docker image reference to run on the instance. Build and push backend/Dockerfile to a registry, then point this at it."
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9./_:@-]*$", var.backend_image))
    error_message = "backend_image must be a Docker image reference without whitespace."
  }
}

variable "instance_label" {
  description = "Label for the Vultr instance and related resources."
  type        = string
  default     = "inview-backend"
}
