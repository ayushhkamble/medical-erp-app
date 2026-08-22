variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "domain_names" {
  type = list(string)
}

variable "acm_certificate_arn" {
  type = string
}

variable "cloudfront_price_class" {
  type    = string
  default = "PriceClass_100"
}

variable "tags" {
  type    = map(string)
  default = {}
}