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
variable network_address_space {
  type = map(string) #Only submitm strings
}
variable "instance_size" {
  type = map(string)
}
variable "subnet_count" {
  type = map(number)
}
variable "instance_count" {
  type = map(number)#You can only submit numbers
}

variable "billing_code_tag" {}
variable "bucket_name_prefix" {}

variable "arm_subscription_id" {}
variable "arm_principal" {}
variable "arm_password" {}
variable "tenant_id" {}
variable "dns_zone_name" {}
variable "dns_resource_group" {}

##################################################################################
# LOCALS
##################################################################################

locals {     #applying lower case
  env_name = lower(terraform.workspace) #defining env name and extracting the value from special resource terraform.workspace
                                        #Whatever your current workspace is, its stored in terraform.workspace
  common_tags = {
    BillingCode = var.billing_code_tag
    Environment = local.env_name #Using the env to set the tag
  }
                                                #using env_name again
  s3_bucket_name = "${var.bucket_name_prefix}-${local.env_name}-${random_integer.rand.result}"


}