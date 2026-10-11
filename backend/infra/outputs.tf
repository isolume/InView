output "instance_ip" {
  description = "Public IPv4 address of the backend instance."
  value       = vultr_instance.backend.main_ip
}

output "backend_url" {
  description = "Set this as INVIEW_BACKEND_URL (or enter it in the app's scan processing settings)."
  value       = var.backend_domain != "" ? "https://${var.backend_domain}" : "https://${replace(vultr_instance.backend.main_ip, ".", "-")}.sslip.io"
}

output "ssh_command" {
  value = "ssh root@${vultr_instance.backend.main_ip}"
}
