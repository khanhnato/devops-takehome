variable "zone_id" {
  description = "Cloudflare zone ID of example.com."
  type        = string
}

variable "origin_hostname" {
  description = "Origin the proxied record points to (e.g. the AWS ALB / ingress hostname)."
  type        = string
  default     = "quote-api-origin.example.net"
}

variable "legacy_record_id" {
  description = "ID of the manually created www.example.com record being adopted (GET /zones/{zone_id}/dns_records?name=www.example.com)."
  type        = string
}
