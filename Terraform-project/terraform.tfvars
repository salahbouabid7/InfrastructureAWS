name_asg = "webserver"

subnet_definitions = {
  "public-subnet-alb" = {
        subnet_name = "public-subnet-alb"
        cidr_block= "10.10.6.0/24"
  }
  "public-subnet-nat" = {
        subnet_name = "public-subnet-nat"
        cidr_block= "10.10.7.0/24"
  }
  "private-subnet-web" = {
        subnet_name = "private-subnet-web"
        cidr_block= "10.10.8.0/24"
  }
}
