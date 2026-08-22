variable "domain_name" {
  type = string
}

variable "frontend_subdomain" {
  type = string
}

variable "api_subdomain" {
  type = string
}

variable "cloudfront_domain_name" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}