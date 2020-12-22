#Using the count resource argument to dynamically generate both the subnets and
#the EC2 instnaces that are going to live in those subnets
##################################################################################
# VARIABLES
##################################################################################

variable "aws_access_key" {}
variable "aws_secret_key" {}
variable "private_key_path" {}
variable "key_name" {}
variable "region" {
  default = "us-east-2"
}
#No longer defining subnets only overall VPC Network Address Space
variable "network_address_space" {
  default = "10.1.0.0/16"
}

variable "billing_code_tag" {}
variable "environment_tag" {}
variable "bucket_name_prefix" {}

#New Variables found in the vars file
variable "arm_subscription_id" {}
variable "arm_principal" {}
variable "arm_password" {}
variable "tenant_id" {}
variable "dns_zone_name" {} #Name of DNS zone we're going to be using
variable "dns_resource_group" {} #Where that DNS zone is stored

#New Variables to create two subnets and 2 instances 
variable "instance_count" {
  default = 2 #Can create as many insntaces as you want
}
variable "subnet_count" {
  default = 2 #The we currently have can be higher than number of azs
}

##################################################################################
# PROVIDERS
##################################################################################

provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
}

#Defining Azure provider
#provider "azurerm" {
#  version = "~> 1.0"
#  subscription_id = var.arm_subscription_id #passing variable values to the different arguments
#  client_id       = var.arm_principal
#  client_secret   = var.arm_password
#  tenant_id       = var.tenant_id
#  alias           = "arm-1" #Adding an alias to refer to it
#}

##################################################################################
# LOCALS
##################################################################################

locals {
  common_tags = {
    BillingCode = var.billing_code_tag
    Environment = var.environment_tag
  }

  s3_bucket_name = "${var.bucket_name_prefix}-${var.environment_tag}-${random_integer.rand.result}"
}

##################################################################################
# DATA
##################################################################################

data "aws_availability_zones" "available" {}

data "aws_ami" "aws-linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-hvm*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

##################################################################################
# RESOURCES
##################################################################################

#Random ID
resource "random_integer" "rand" {
  min = 10000
  max = 99999
}

# NETWORKING #
resource "aws_vpc" "vpc" {
  cidr_block = var.network_address_space

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-vpc" })

}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-igw" })

}

resource "aws_subnet" "subnet" {
  count                   = var.subnet_count #This case 2
  cidr_block              = cidrsubnet(var.network_address_space, 8, count.index)#Passing VPC network address space,adding 8bits to subnet mask, using cout.index to get first and second subnet
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]#Using count to tell which AZ to use

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-subnet${count.index + 1}" })#To make more readable adding 1 to count.indext to start with 1 instead of 0

}

# ROUTING #
resource "aws_route_table" "rtb" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-rtb" })
}

resource "aws_route_table_association" "rta-subnet" {
  count          = var.subnet_count
  subnet_id      = aws_subnet.subnet[count.index].id#Resource subnet is compiled inot a list and we are using count.index to retrieve each subnet for the list, really what we ant is the ID hense .id
  route_table_id = aws_route_table.rtb.id
}

# SECURITY GROUPS #
resource "aws_security_group" "elb-sg" {
  name   = "nginx_elb_sg"
  vpc_id = aws_vpc.vpc.id

  #Allow HTTP from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-elb-sg" })
}

# Nginx security group 
resource "aws_security_group" "nginx-sg" {
  name   = "nginx_sg"
  vpc_id = aws_vpc.vpc.id

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from the VPC
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.network_address_space]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-nginx-sg" })
}

# LOAD BALANCER #
resource "aws_elb" "web" {
  name = "nginx-elb"

  subnets         = aws_subnet.subnet[*].id#[*] basically says, return all of the list elements (IDs) and package it in a list form. The "subnets" argument for LB is expecting a list object
  security_groups = [aws_security_group.elb-sg.id]
  instances       = aws_instance.nginx[*].id#Same usage of [*] sometimes called splat

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-elb" })
}

# INSTANCES #
resource "aws_instance" "nginx" {
  count                  = var.instance_count #We put it to 2
  ami                    = data.aws_ami.aws-linux.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.subnet[count.index % var.subnet_count].id #palcing this ec2 instnace on subnet, only have two subnets, in case we have more intances using modulo operator, no matter how many instnaces we give it, the odd instances are going to end up in subnet 1, and the even sintances are going to end up in subnet2. 
  vpc_security_group_ids = [aws_security_group.nginx-sg.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.nginx_profile.name
  depends_on             = [aws_iam_role_policy.allow_s3_all]

  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ec2-user"
    private_key = file(var.private_key_path)

  }

  provisioner "file" {
    content = <<EOF
access_key =
secret_key =
security_token =
use_https = True
bucket_location = US

EOF
    destination = "/home/ec2-user/.s3cfg"
  }

  provisioner "file" {
    content = <<EOF
/var/log/nginx/*log {
    daily
    rotate 10
    missingok
    compress
    sharedscripts
    postrotate
    endscript
    lastaction
        INSTANCE_ID=`curl --silent http://169.254.169.254/latest/meta-data/instance-id`
        sudo /usr/local/bin/s3cmd sync --config=/home/ec2-user/.s3cfg /var/log/nginx/ s3://${aws_s3_bucket.web_bucket.id}/nginx/$INSTANCE_ID/
    endscript
}

EOF

    destination = "/home/ec2-user/nginx"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install nginx -y",
      "sudo service nginx start",
      "sudo cp /home/ec2-user/.s3cfg /root/.s3cfg",
      "sudo cp /home/ec2-user/nginx /etc/logrotate.d/nginx",
      "sudo pip install s3cmd",
      "s3cmd get s3://${aws_s3_bucket.web_bucket.id}/website/index.html .",
      "s3cmd get s3://${aws_s3_bucket.web_bucket.id}/website/Globo_logo_Vert.png .",
      "sudo cp /home/ec2-user/index.html /usr/share/nginx/html/index.html",
      "sudo cp /home/ec2-user/Globo_logo_Vert.png /usr/share/nginx/html/Globo_logo_Vert.png",
      "sudo logrotate -f /etc/logrotate.conf"
      
    ]
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-nginx${count.index + 1}" })
}

# S3 Bucket config#
resource "aws_iam_role" "allow_nginx_s3" {
  name = "allow_nginx_s3"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "nginx_profile" {
  name = "nginx_profile"
  role = aws_iam_role.allow_nginx_s3.name
}

resource "aws_iam_role_policy" "allow_s3_all" {
  name = "allow_s3_all"
  role = aws_iam_role.allow_nginx_s3.name

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:*"
      ],
      "Effect": "Allow",
      "Resource": [
                "arn:aws:s3:::${local.s3_bucket_name}",
                "arn:aws:s3:::${local.s3_bucket_name}/*"
            ]
    }
  ]
}
EOF

  }

  resource "aws_s3_bucket" "web_bucket" {
    bucket        = local.s3_bucket_name
    acl           = "private"
    force_destroy = true

    tags = merge(local.common_tags, { Name = "${var.environment_tag}-web-bucket" })

  }

  resource "aws_s3_bucket_object" "website" {
    bucket = aws_s3_bucket.web_bucket.bucket
    key    = "/website/index.html"
    source = "./index.html"

  }

  resource "aws_s3_bucket_object" "graphic" {
    bucket = aws_s3_bucket.web_bucket.bucket
    key    = "/website/Globo_logo_Vert.png"
    source = "./Globo_logo_Vert.png"

  }

  # Azure RM DNS # 
  #Where we are defining that DNS record that we want to add to DNS zone
  #esource "azurerm_dns_cname_record" "elb" {
  #  name                = "${var.environment_tag}-website" #Record name to be refered to
  #  zone_name           = var.dns_zone_name
  #  resource_group_name = var.dns_resource_group
  #  ttl                 = "30" #how long the record is valid seconds
  #  record              = aws_elb.web.dns_name #Record field tells it where this CNAME record should be pointing to, this case public DNS name of the elastic load balancer
  #  provider            = azurerm.arm-1 #tellign what provider to use
#
#    tags = merge(local.common_tags, { Name = "${var.environment_tag}-website" })
#  }

  ##################################################################################
  # OUTPUT
  ##################################################################################

  output "aws_elb_public_dns" {
    value = aws_elb.web.dns_name
  }

  output "cname_record_url" {
    value = "http://${var.environment_tag}-website.${var.dns_zone_name}"
  }
