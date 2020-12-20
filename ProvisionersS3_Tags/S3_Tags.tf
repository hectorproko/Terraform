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
variable "network_address_space" {
  default = "10.1.0.0/16"
}
variable "subnet1_address_space" {
  default = "10.1.0.0/24"
}
variable "subnet2_address_space" {
  default = "10.1.1.0/24"
}

#New variables, found in variables file
variable "bucket_name_prefix" {}
variable "billing_code_tag" {}
variable "environment_tag" {}

##################################################################################
# PROVIDERS
##################################################################################

provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
}

##################################################################################
# LOCALS
##################################################################################

locals { #Locals allows us to defines some local values to use in the configuration
  common_tags = {#Map type object
    BillingCode = var.billing_code_tag
    Environment = var.environment_tag
  }
  #Using Interpolation
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
resource "random_integer" "rand" {#Generates random number fot S3 unique global name 
                                  #you the the generate number with random_integer.rand.result
  min = 10000 #number type, not string
  max = 99999
}


# NETWORKING #
resource "aws_vpc" "vpc" {
  cidr_block = var.network_address_space
         #Merge takes two mapped objects and combines the into a single map
  tags = merge(local.common_tags, { Name = "${var.environment_tag}-vpc" })                                      
}                                  #Create second map on the fly

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-igw" })

}

resource "aws_subnet" "subnet1" {
  cidr_block              = var.subnet1_address_space
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = "true"
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-subnet1" })

}

resource "aws_subnet" "subnet2" {
  cidr_block              = var.subnet2_address_space
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = "true"
  availability_zone       = data.aws_availability_zones.available.names[1]

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-subnet2" })

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

resource "aws_route_table_association" "rta-subnet1" {
  subnet_id      = aws_subnet.subnet1.id
  route_table_id = aws_route_table.rtb.id
}

resource "aws_route_table_association" "rta-subnet2" {
  subnet_id      = aws_subnet.subnet2.id
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

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-elb" })

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

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-nginx" })

}

# LOAD BALANCER #
resource "aws_elb" "web" {
  name = "nginx-elb"

  subnets         = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
  security_groups = [aws_security_group.elb-sg.id]
  instances       = [aws_instance.nginx1.id,aws_instance.nginx2.id]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-elb" })

}

# INSTANCES #
resource "aws_instance" "nginx1" {
  ami                    = data.aws_ami.aws-linux.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.subnet1.id
  vpc_security_group_ids = [aws_security_group.nginx-sg.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.nginx_profile.name#Because we want to grant this instance access to an S3 Bucket
                                                                      #we are creating an instance profile for it to assume and gain access
  connection {                                                        #there is resource aws_iam_instance_profile defined
    type        = "ssh"
    host        = self.public_ip
    user        = "ec2-user"
    private_key = file(var.private_key_path)

  }#The provisioners are reliying on this connection to reach out to this remote instance

#Provisioner of type file #We are defining the content of the file inline by using the heredox syntax
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
                       #Further explaning in line 441
  # another file provisioner with inline content
  #using logrotate to rotate the logs for our nginx, logrotate provides the ability to run script after the logrotate action happens line 262
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
      "sudo cp /home/ec2-user/.s3cfg /root/.s3cfg", #copying .s3cfg file from user dir to root dir because when you run file provisioner it does not have sudo access, so it can only copy to a dir where ec2-user has access to
      "sudo cp /home/ec2-user/nginx /etc/logrotate.d/nginx",#logrotate.d dir is where logrotate finds all of the configuration files for diff services
      "sudo pip install s3cmd", #using pip to install s3cmd software
      "s3cmd get s3://${aws_s3_bucket.web_bucket.id}/website/index.html .", #Getting Globo and index out of the bucket, to home/ec2-user/
      "s3cmd get s3://${aws_s3_bucket.web_bucket.id}/website/Globo_logo_Vert.png .",
      "sudo cp /home/ec2-user/index.html /usr/share/nginx/html/index.html",#cp to default nginx install folder, default page that loads when nginx runs
      "sudo cp /home/ec2-user/Globo_logo_Vert.png /usr/share/nginx/html/Globo_logo_Vert.png",
      "sudo logrotate -f /etc/logrotate.conf" #Forcing a rotation of the logs so that we can see the logs being copied from instance up to the S3 bucket
      
    ]
  }

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-nginx1" })

}

resource "aws_instance" "nginx2" {
  ami                    = data.aws_ami.aws-linux.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.subnet2.id
  vpc_security_group_ids = [aws_security_group.nginx-sg.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.nginx_profile.name

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

  tags = merge(local.common_tags, { Name = "${var.environment_tag}-nginx2" })

}

# S3 Bucket config#
#baasically copy pasting roel policy JSON straigh from AWS
#A role that EC2 instances can assume
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

resource "aws_iam_instance_profile" "nginx_profile" { # Where we define the instance profile
  name = "nginx_profile"
  role = aws_iam_role.allow_nginx_s3.name # role that the instance will be allow to assume
}

resource "aws_iam_role_policy" "allow_s3_all" {#Creating a policy for that role
  name = "allow_s3_all"
  role = aws_iam_role.allow_nginx_s3.name #Provide the role that we are associating
  #Grants all s3 actions line 396 to two resources line 400 (the s3 bucket itself) 401 all contents of that bucket
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

  resource "aws_s3_bucket" "web_bucket" { #Creating bucket
    bucket        = local.s3_bucket_name #bucket name which we defined on the locals values
    acl           = "private" #so its not a public S3
    force_destroy = true #Terrafrom will abe able to destroy this bucket even if is not empty

    tags = merge(local.common_tags, { Name = "${var.environment_tag}-web-bucket" }) #Giving it the common set of stag

  }
  #The next two resources are meant to upload index and png file to this S3 bucket
  resource "aws_s3_bucket_object" "website" {
    bucket = aws_s3_bucket.web_bucket.bucket
    key = "/website/index.html"
    source = "./index.html"

  }

  resource "aws_s3_bucket_object" "graphic" {
    bucket = aws_s3_bucket.web_bucket.bucket
    key = "/website/Globo_logo_Vert.png"
    source = "./Globo_logo_Vert.png"

  }

  ##################################################################################
  # OUTPUT
  ##################################################################################

  output "aws_elb_public_dns" {
    value = aws_elb.web.dns_name
  }

#Line 331 and 332 explained
# 331       INSTANCE_ID=`curl --silent http://169.254.169.254/latest/meta-data/instance-id`
            #Gettign instnace ID from the metadata service for EC2 instnace and storing it in variable
# 332       sudo /usr/local/bin/s3cmd sync --config=/home/ec2-user/.s3cfg /var/log/nginx/ s3://${aws_s3_bucket.web_bucket.id}/nginx/$INSTANCE_ID/
            #running S3cmmod with sync     #pointing it to where the      #source directo  #giving it destination s3 bucket where we want it to place 
            #argument to tell it to        #configuration for s3cmd       #from where it   #place those files, using interpolation here
            #syncronize files to a         #is stored                     #should copy files
            #destination