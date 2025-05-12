
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 8.6.0"
    }
  }
}
locals {
  vpc_id = "vpc-09b443006b8470e8b"
  public_subnet_ids = [
    for name, subnet in aws_subnet.subnets :
    subnet.id
    if strcontains(subnet.tags["Name"], "public-subnet")
  ]

}
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
data "aws_vpc" "AWSvpc" {
  filter {
    name   = "id"
    values = [local.vpc_id]
  }
}
data "aws_internet_gateway" "default" {
  filter {
    name   = "internet-gateway-id"
    values = [var.internetgateway]
  }
}

module "autoscaling" {
  source           = "terraform-aws-modules/autoscaling/aws"
  version          = "8.3.0"
  name             = "webapp-asg"
  min_size         = 1
  max_size         = 3
  desired_capacity = 1
  #Configuration of the Launch Template
  launch_template_name        = "webserver"
  launch_template_description = "Launch template example"
  update_default_version      = true
  image_id                    = data.aws_ami.ubuntu.image_id
  instance_type               = "t3.micro"
  termination_policies        = ["ClosestToNextInstanceHour", "Default"]
  vpc_zone_identifier         = aws_subnet.webapp-subnet.id
  scaling_policies = [
    {
      name                = "scale-out"
      policy_type         = "SimpleScaling"
      adjustment_type     = "ChangeInCapacity"
      scaling_adjustment  = 1
      cooldown            = 300
      metric_name         = "CPUUtilization"
      namespace           = "AWS/EC2"
      statistic           = "Average"
      period              = 60
      evaluation_periods  = 5
      threshold           = 95
      comparison_operator = "GreaterThanThreshold"
    },
    {
      name                = "scale-in"
      policy_type         = "SimpleScaling"
      adjustment_type     = "ChangeInCapacity"
      scaling_adjustment  = -1
      cooldown            = 300
      metric_name         = "CPUUtilization"
      namespace           = "AWS/EC2"
      statistic           = "Average"
      period              = 60
      evaluation_periods  = 5
      threshold           = 50
      comparison_operator = "LessThanThreshold"
    }
  ]
  security_groups  = [aws_security_group.asg_to_rds.id]
  default_cooldown = 600
  target_group_arns = [module.alb.target_groups["asg_group"].arn]

}

resource "aws_subnet" "subnets" {
  vpc_id            = local.vpc_id
  for_each          = var.subnet_definitions
  cidr_block        = each.value.cidr_block
  availability_zone = "eu-north-1b"

  tags = {
    Name = each.value.subnet_name
  }
}

resource "aws_route_table" "webapp-routetable" {
  vpc_id = local.vpc_id
  route {
    cidr_block = "10.0.0.0/16"
    gateway_id = "local"
  }

}

resource "aws_route" "webapp-route" {
  route_table_id         = aws_route_table.webapp-routetable.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.default.id
}
#####
resource "aws_route_table" "nat-routetable" {
  vpc_id = local.vpc_id
  route {
    cidr_block = "10.0.0.0/16"
    gateway_id = "local"
  }

}

resource "aws_route" "nat-route" {
  route_table_id         = aws_route_table.nat-routetable.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_nat_gateway.awsnatgateway.id
}

resource "aws_nat_gateway" "awsnatgateway" {
  allocation_id = aws_eip.publicip.id
  subnet_id     = aws_subnet.subnets["public-subnet-nat"].id
  tags = {
    Name = "gw NAT"
  }

  depends_on = [data.aws_internet_gateway.default]
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.subnets["public-subnet-nat"].id
  route_table_id = aws_route_table.nat-routetable.id
}
resource "aws_eip" "publicip" {
  depends_on                = [data.aws_internet_gateway.default]
}
######
resource "aws_route_table_association" "a" {
  count = length(local.public_subnet_ids)
  subnet_id      = local.public_subnet_ids[count.index]
  route_table_id = aws_route_table.webapp-routetable.id
}

resource "aws_security_group" "rds-to-asg" {
  name        = "rds-to-asg"
  vpc_id      = local.vpc_id
  description = "Allows inbound MySQL traffic from EC2/ASG instances"

  tags = {
    Name = "allow_RDStoASG"
  }
}

resource "aws_security_group" "asg-to-rds" {
  name        = "asg-to-rds"
  vpc_id      = local.vpc_id
  description = "Allows outbound MySQL traffic to RDS"


  tags = {
    Name = "allow_tls"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rdstoasg_ingress" {
  security_group_id            = aws_security_group.rds-to-asg
  from_port                    = 3306
  ip_protocol                  = "tcp"
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.asg_to_rds.id
  description                  = "Allow inbound DB traffic from EC2/ASG on port 3306"

}

resource "aws_vpc_security_group_egress_rule" "asg-to-rds" {
  security_group_id            = aws_security_group.asg-to-rds
  from_port                    = 3306
  ip_protocol                  = "tcp"
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.rds-to-asg.id
  description                  = "Allow outbound DB traffic to RDS on port 3306"

}
module "alb" {

  source             = "terraform-aws-modules/alb/aws"
  name               = "alb_for_asg"
  vpc_id             = local.vpc_id
  subnets            = [aws_subnet.subnets["public-subnet-alb"].id]
  load_balancer_type = "application"
  internal           = false
  security_group_ingress_rules = {
    allow_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "HTTP web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
    allow_https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      description = "HTTPS web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = data.aws_vpc.AWSvpc.cidr_block
    }
  }

  target_groups = {
    asg_group = {
      name_prefix = "asg_targetgroup"
      target_type = "instance"
      port        = 80
      protocol    = "TCP"
    }
  }
  listeners = {
    tcp80 = {
      port     = 80
      protocol = "TCP"
      forward = {
        target_group_key = "asg_group"
      }
    }
    tcp443 = {
      port     = 443
      protocol = "TCP"
      forward = {
        target_group_key = "asg_group"
      }
    }
  }
}