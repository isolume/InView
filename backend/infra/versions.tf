terraform {
  required_version = ">= 1.6"
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.33"
    }
  }
}

provider "vultr" {
  api_key = var.vultr_api_key
}
