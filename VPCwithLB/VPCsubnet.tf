##################################################################################
# VARIABLES
##################################################################################

variable "aws_access_key" {} #Same variable as pervious module
variable "aws_secret_key" {}
variable "private_key_path" {}
variable "key_name" {}
variable "region" {
  default = "us-east-2"
}
variable "network_address_space" { #New varaibles 
  default = "10.1.0.0/16"
}
variable "subnet1_address_space" {
  default = "10.1.0.0/24"
}

##################################################################################
# PROVIDERS
##################################################################################

provider "aws" { #providers same as before
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
}

##################################################################################
# DATA
##################################################################################

data "aws_availability_zones" "available" {} #Getting availability zone available
                                             #Because we are spinning a subnet in an availability zone
data "aws_ami" "aws-linux" { #data source that is grabbing the most 
  most_recent = true         #recent AMI of Amazon linux
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

# NETWORKING #
resource "aws_vpc" "vpc" { #Deploying the VPC and passing our cidr
  cidr_block           = var.network_address_space
  enable_dns_hostnames = "true"

}

resource "aws_internet_gateway" "igw" { #gateway
  vpc_id = aws_vpc.vpc.id #what vpc to attach it to

}

resource "aws_subnet" "subnet1" {
  cidr_block              = var.subnet1_address_space #What cidr block to use
  vpc_id                  = aws_vpc.vpc.id #vpc where subet shoudl be created
  map_public_ip_on_launch = "true" #map a public ip on launch as well as an internal private ip
  availability_zone       = data.aws_availability_zones.available.names[0] #pick the name of the first availability zone from data source

}

# ROUTING #
resource "aws_route_table" "rtb" { #route table, creating default route to get out of that vpc
  vpc_id = aws_vpc.vpc.id          #pointing it at the internet gateway

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rta-subnet1" { #route table association where we are
  subnet_id      = aws_subnet.subnet1.id               #associating this table with that one subnet that
  route_table_id = aws_route_table.rtb.id              #we created
}

# SECURITY GROUPS #
# Nginx security group 
resource "aws_security_group" "nginx-sg" { #Same security groups
  name   = "nginx_sg"
  vpc_id = aws_vpc.vpc.id

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# INSTANCES #
resource "aws_instance" "nginx1" {
  ami                    = data.aws_ami.aws-linux.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.subnet1.id #We are telling it that we want to put this instance in subnet1
  vpc_security_group_ids = [aws_security_group.nginx-sg.id] #The security group that allows port 22 and 80
  key_name               = var.key_name

  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ec2-user"
    private_key = file(var.private_key_path)

  }

  provisioner "remote-exec" { #Basically runs a script on the remote instance
    inline = [
      "sudo yum install nginx -y",
      "sudo service nginx start",
      "echo '<html><head><title>Blue Team Server</title></head><body style=\"background-color:#1F778D\"><p style=\"text-align: center;\"><span style=\"color:#FFFFFF;\"><span style=\"font-size:28px;\">Blue Team</span></span></p></body></html>' | sudo tee /usr/share/nginx/html/index.html"
    ]
  }
}

##################################################################################
# OUTPUT
##################################################################################

output "aws_instance_public_dns" { #we are getting the public dns entry
  value = aws_instance.nginx1.public_dns
}
