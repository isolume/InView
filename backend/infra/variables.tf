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
  description = "Vultr instance plan. vc2-1c-1gb is the smallest shared-CPU plan, enough for this in-memory prototype service."
  type        = string
  default     = "vc2-1c-1gb"
}

variable "ssh_public_key" {
  description = "Your public key (e.g. contents of ~/.ssh/id_ed25519.pub), for SSH access to the instance."
  type        = string
}

variable "backend_port" {
  description = "Port the InView backend listens on and the firewall opens to the internet."
  type        = number
  default     = 3000
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into the instance. Restrict this to your own IP (e.g. \"203.0.113.4/32\") instead of leaving it open."
  type        = string
  default     = "0.0.0.0/0"
}

variable "backend_image" {
  description = "Docker image reference to run on the instance. Build and push backend/Dockerfile to a registry, then point this at it."
  type        = string
  default     = "ghcr.io/example/inview-backend:latest"
}

variable "instance_label" {
  description = "Label for the Vultr instance and related resources."
  type        = string
  default     = "inview-backend"
}
