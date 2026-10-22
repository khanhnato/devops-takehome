terraform {
  required_version = ">= 1.7"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
  }

  # Validate-only in this repo. In prod: remote state with locking, e.g.
  # backend "s3" { bucket = "acme-tf-state", key = "cloudflare/example.com.tfstate", use_lockfile = true }
}

# Credentials come from the CLOUDFLARE_API_TOKEN environment variable (scoped
# token: Zone.DNS:Edit + Zone.Cache Rules:Edit on this zone only). Never in code.
provider "cloudflare" {}
