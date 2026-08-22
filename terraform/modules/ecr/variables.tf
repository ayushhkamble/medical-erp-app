variable "repositories" {
  type = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}