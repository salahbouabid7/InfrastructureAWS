
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.0.0-beta1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.1.0"
    }
  }
}

provider "aws" {
  region     = "eu-north-1"
  access_key = "AKIA3FLDYFT3ZD36P3VP"
  secret_key = "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"
}

locals {
  vpc_id = "vpc-09b443006b8470e8b"
  public_subnet_ids = [
    for name, subnet in aws_subnet.subnets :
    subnet.id
    if strcontains(subnet.tags["Name"], "public-subnet")
  ]
  publickeyinstance = "asgkey"
}
# END #

# Retrieving DATA FROM AWS #
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

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
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}
data "aws_security_group" "azureconnectAWSDatabse" {
  id = "sg-01394212b4d0dcbac"
}
data "aws_security_group" "default"{
  id = "sg-0ab01d3579a8d1559"
}
data "aws_internet_gateway" "default" {
  filter {
    name   = "tag:Name"
    values = [var.internetgateway]
  }
}
data "aws_instances" "instanceASG" {
  instance_tags = {
  Name = "ASG-instance" }
  
}
data "aws_db_instance" "database" {
  db_instance_identifier = "databaseaws"
}
data "aws_subnet" "subnet-lambda" {
  vpc_id = local.vpc_id
  filter {
    name = "tag:Name"
    values = ["LambdaSub"]
  }
}

# END #
# Auto Scaling Group Module #
module "autoscaling" {
  source           = "./ASG"
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
  vpc_zone_identifier         = [aws_subnet.subnets["private-subnet-web"].id]
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
  security_groups  = [aws_security_group.asg-to-rds.id, aws_security_group.asg-cb.id]
  default_cooldown = 600
  traffic_source_attachments = {
    asg-alb = {
      traffic_source_identifier = module.alb.target_groups["asg_group"].arn
      type                      = "elbv2"
    }
  }
  launch_template_tags = {
    Name = "ASG-instance"
  }
  key_name = local.publickeyinstance
 ## Parssing the private ip of the instance into inventory file of ansible ##
  user_data = base64encode(<<-EOF
  #!/bin/bash
  echo "${module.alb.dns_name}" > /home/ubuntu/alb.dns
  chown ubuntu:ubuntu /home/ubuntu/alb.dns
EOF
)
  
}
# END #
## Parssing the private ip of the instance into inventory file of ansible ##



## Génerating Keys (Private/Public) that will be used later on ansible for configuration ##
resource "aws_key_pair" "public-key" {
  key_name   = local.publickeyinstance
  public_key = tls_private_key.keyforasg.public_key_openssh

  provisioner "local-exec" {
    working_dir = "../automation_ansible/"
    command     = <<SALAH
cat <<EOF > private_key.pem
${tls_private_key.keyforasg.private_key_openssh}
EOF
chmod 600 private_key.pem
SALAH
  }
}
resource "tls_private_key" "keyforasg" {
  algorithm = "RSA"
}
############## END OF RESSOURCE RELATED TO PRIVATE/PUBLIC KEY ##


# Creating ressource related to VPC #
resource "aws_subnet" "subnets" {
  vpc_id            = local.vpc_id
  for_each          = var.subnet_definitions
  cidr_block        = each.value.cidr_block
  availability_zone = "eu-north-1b"

  tags = {
    Name = each.value.subnet_name
  }
}

resource "aws_subnet" "alb-second" {
  vpc_id            = local.vpc_id
  cidr_block        = "10.10.9.0/24"
  availability_zone = "eu-north-1a"

  tags = {
    Name = "alb-subnet-eu-north-1a"
  }
}
## creating  table route ##
resource "aws_route_table" "webapp-routetable" {
  vpc_id = local.vpc_id
  tags = {
    Name = "webapp-routetable"
  }
}

resource "aws_route" "webapp-route" {
  route_table_id         = aws_route_table.webapp-routetable.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.default.id
}

resource "aws_route_table" "nat-routetable" {
  vpc_id = local.vpc_id
  tags = {
    Name = "nat-routetable"
  }
}

resource "aws_route" "nat-route" {
  route_table_id         = aws_route_table.nat-routetable.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_nat_gateway.awsnatgateway.id
}

### ASSOCIATING TABLE ROUTE WITH SUBNET ###
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.subnets["private-subnet-web"].id
  route_table_id = aws_route_table.nat-routetable.id
}
resource "aws_route_table_association" "alb-b" {
  subnet_id      = aws_subnet.alb-second.id
  route_table_id = aws_route_table.nat-routetable.id
}
resource "aws_route_table_association" "a" {
  count          = length(local.public_subnet_ids)
  subnet_id      = local.public_subnet_ids[count.index]
  route_table_id = aws_route_table.webapp-routetable.id
}
### END ###
## END ##

## Creating NAT GATEWAY AND ELASTIC IP ##
resource "aws_nat_gateway" "awsnatgateway" {
  allocation_id = aws_eip.publicip.id
  subnet_id     = aws_subnet.subnets["public-subnet-nat"].id
  tags = {
    Name = "gw NAT"
  }

  depends_on = [data.aws_internet_gateway.default]
}
resource "aws_eip" "publicip" {
  depends_on = [data.aws_internet_gateway.default]
}
## END ##
#END#

# Creating Security Group #
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
  security_group_id            = aws_security_group.rds-to-asg.id
  from_port                    = 3306
  ip_protocol                  = "tcp"
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.asg-to-rds.id
  description                  = "Allow inbound DB traffic from EC2/ASG on port 3306"

}

resource "aws_vpc_security_group_egress_rule" "asg-to-rds" {
  security_group_id            = aws_security_group.asg-to-rds.id
  from_port                    = 3306
  ip_protocol                  = "tcp"
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.rds-to-asg.id
  description                  = "Allow outbound DB traffic to RDS on port 3306"
}
 ### Attach the Security group to the RDS ###
 resource "aws_db_instance" "existing_rds" {
  identifier = data.aws_db_instance.database.id
  instance_class = data.aws_db_instance.database.db_instance_class
  vpc_security_group_ids = [aws_security_group.rds-to-asg.id, data.aws_security_group.azureconnectAWSDatabse.id, data.aws_security_group.default.id]
  lifecycle {
    ignore_changes = [
     allocated_storage,
     engine,
     engine_version,
     instance_class,
     db_name,
     username,
     password,
     backup_retention_period,
     multi_az,
     storage_type,
     deletion_protection,
     storage_encrypted,
     tags
    ]
 }
 }
# END #
## Configure Security group for Ansible (codebuild) to access asg##

resource "aws_security_group" "asg-cb" {
  name        = "asg-instance-sg"
  vpc_id      = local.vpc_id
  description = "Security group for EC2 instances in ASG; allows SSH from CodeBuild"

  tags = {
    Name = "allow_SSH"
  }
}
resource "aws_security_group" "cb-asg" {
  name        = "codebuild-sg"
  vpc_id      = local.vpc_id
  description = "Security group for AWS CodeBuild; used to connect to EC2 instances via SSH"

  tags = {
    Name = "codebuild-sg"
  }
}
resource "aws_vpc_security_group_ingress_rule" "ASGcb_ingress" {
  security_group_id            = aws_security_group.asg-cb.id
  from_port                    = 22
  ip_protocol                  = "tcp"
  to_port                      = 22
  referenced_security_group_id =  aws_security_group.cb-asg.id
  description                  = "Allow inbound SSH from CodeBuild to ASG instances "
}
resource "aws_vpc_security_group_egress_rule" "CBasg_egress" {
  security_group_id            = aws_security_group.cb-asg.id
  from_port                    = 22
  ip_protocol                  = "tcp"
  to_port                      = 22
  referenced_security_group_id = aws_security_group.asg-cb.id
  description                  = "Allow outbound SSH from CodeBuild to ASG instances"
}
## END ##
### Updating the coldebuild with appropriate vpc ###
resource "aws_codebuild_project" "project-using-github-app" {
  name         = "Deploy-Terraform"
  description  = "Instancuat the aws infra , Clone Web application from github and running it"
  service_role = "arn:aws:iam::767397735671:role/service-role/codebuild-Deploy-Terraform-service-role"

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"

  }

  source {
    type     = "GITHUB"
    location = "https://github.com/salahbouabid7/InfrastructureAWS"
    git_clone_depth = 1
  }
  vpc_config {
    vpc_id = local.vpc_id
    subnets = [data.aws_subnet.subnet-lambda.id]
    security_group_ids = [aws_security_group.cb-asg.id]
  }
  lifecycle {
    prevent_destroy = true
  }
}
###



# Creating LOAD BALANCR #
module "alb" {

  source                     = "./ALB"
  name                       = "alb-for-asg"
  vpc_id                     = local.vpc_id
  subnets                    = [aws_subnet.subnets["public-subnet-alb"].id, aws_subnet.alb-second.id]
  load_balancer_type         = "application"
  internal                   = false
  enable_deletion_protection = false
  security_group_ingress_rules = {
    allow_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "HTTP web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }

    allow_frontend = {
      from_port   = 3000
      to_port     = 3000
      ip_protocol = "tcp"
      description = "Allow external access to frontend app"
      cidr_ipv4   = "0.0.0.0/0"
    }
    allow_backend = {
      from_port   = 8000
      to_port     = 8000
      ip_protocol = "tcp"
      description = "Allow external access to backend"
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
      name_prefix = "asg-tg"
      target_type = "instance"
      port        = 80
      protocol    = "HTTP"
      health_check = {
        enabled             = false
      }
    }
  }

  listeners = {
    tcp80 = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "asg_group"
      }
    }
    tcp3000 = {
      port     = 3000
      protocol = "HTTP"
      forward = {
        target_group_key = "asg_group"
      }
    }
    tcp8000 = {
      port     = 8000
      protocol = "HTTP"
      forward = {
        target_group_key = "asg_group"
      }
    }

  }

}
#
# END #
