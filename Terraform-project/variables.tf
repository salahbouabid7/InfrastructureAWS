

variable "subnet_definitions" {
  type = map(object({
    subnet_name = string
    cidr_block = string
  }))
  description = "Map of subnet definitions"
}

variable "internetgateway" {
  type = string
  description = "Intergat gateway dedie au vpc AWSVP"
}
 