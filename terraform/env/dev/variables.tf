variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "domain_name" {
  type        = string
  description = "Base domain (e.g. yourdomain.com)"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM cert ARN for CloudFront"
}

variable "developer_ip_cidr" {
  type        = string
  description = "CIDR for dev machine accessing EKS endpoint"
}

variable "alb_dns_name" {
  type        = string
  description = "ALB DNS name from ingress"
}