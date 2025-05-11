

variable "subnet_definitions" {
  type = map(object({
    subnet_name = string
    cidr_block = string
  }))
  description = "Map of subnet definitions"
}
