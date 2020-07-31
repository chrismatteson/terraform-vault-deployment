# Example to deploy a single cluster with bastion

provider "aws" {
  region = "us-east-1"
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

resource "random_id" "deployment_tag" {
  byte_length = 4
}

# Local for tag to attach to all items
locals {
  tags = merge(
    var.tags,
    {
      "DeploymentTag" = random_id.deployment_tag.hex
    },
  )
}

resource "local_file" "private_key" {
  sensitive_content = tls_private_key.ssh.private_key_pem
  filename          = "${path.module}/${random_id.deployment_tag.hex}-key.pem"
  file_permission   = "0400"
}

data "aws_availability_zones" "available" {
  state    = "available"
}

module "bastion_vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name   = "${random_id.deployment_tag.hex}-bastion"

  cidr = "192.168.0.0/16"

  azs             = [data.aws_availability_zones.available.names[0]]
  private_subnets = ["192.168.1.0/24"]
  public_subnets  = ["192.168.101.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    Name = "overridden-name-public"
  }

  tags = local.tags

  vpc_tags = {
    Name = "${random_id.deployment_tag.hex}-vpc"
    Purpose = "bastion"
  }
  providers = {
    aws = aws.region1
  }
}

resource "aws_default_security_group" "bastion_default" {
  provider = aws.region1
  vpc_id   = module.bastion_vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "key" {
  provider   = aws.region1
  key_name   = "${random_id.deployment_tag.hex}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# Lookup most recent AMI
data "aws_ami" "latest-image" {
  provider    = aws.region1
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "bastion" {
  provider      = aws.region1
  ami           = data.aws_ami.latest-image.id
  instance_type = "t2.micro"
  subnet_id     = module.bastion_vpc.public_subnets[0]
  key_name      = aws_key_pair.key.key_name
  user_data     = <<EOF
#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y unzip

wget https://releases.hashicorp.com/vault/1.3.2+ent/vault_1.3.2+ent_linux_amd64.zip -O vault.zip
unzip vault
mv vault /usr/bin/vault
EOF

  tags = local.tags
}

module "primary_cluster" {
  source                     = "../../"
  vault_version              = "1.3.2+ent"
  vault_cluster_size         = 3
  enable_deletion_protection = false
  subnet_second_octet        = "0"
  force_bucket_destroy       = true
  tags                       = local.tags
}

resource "aws_vpc_peering_connection" "bastion_connectivity" {
  peer_vpc_id = module.bastion_vpc.vpc_id
  vpc_id      = module.primary_cluster.vpc_id
  auto_accept = true
}

resource "aws_vpc_peering_connection_accepter" "bastion_connectivity_dr" {
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity_dr.id
  auto_accept               = true
}

resource "aws_default_security_group" "primary_cluster" {
  vpc_id   = module.primary_cluster.vpc_id

  ingress {
    protocol  = -1
    self      = true
    from_port = 0
    to_port   = 0
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  ingress {
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = module.bastion_vpc.public_subnets_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_route" "bastion_vpc" {
  count                     = length(setproduct(module.primary_cluster.public_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids))
  route_table_id            = element(setproduct(module.primary_cluster.public_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids), count.index)[1]
  destination_cidr_block    = element(setproduct(module.primary_cluster.public_subnets_cidr_blocks, module.bastion_vpc.public_route_table_ids), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity.id
}

resource "aws_route" "vpc_bastion" {
  provider                  = aws.region1
  count                     = length(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.primary_cluster.route_tables))
  route_table_id            = element(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.primary_cluster.route_tables), count.index)[1]
  destination_cidr_block    = element(setproduct(module.bastion_vpc.public_subnets_cidr_blocks, module.primary_cluster.route_tables), count.index)[0]
  vpc_peering_connection_id = aws_vpc_peering_connection.bastion_connectivity.id
}

