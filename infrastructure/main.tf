terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.15"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

data "aws_ecr_repository" "llm_test_image" {
  name = "llm-test-image"
}

data "aws_iam_policy_document" "ecr_policy" {
  statement {
    sid     = "AllowPull"
    effect  = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:GetAuthorizationToken"  // added this line
    ]

    resources = ["*"]
  }
}


resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_execution_policy" {
  name   = "ecsTaskExecutionPolicy"
  role   = aws_iam_role.ecs_task_execution_role.id
  policy = data.aws_iam_policy_document.ecr_policy.json
}

resource "aws_security_group" "allow_http_ssh" {
  name        = "allow_http_ssh"
  description = "Allow inbound traffic on ports 8000 and 22"

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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


resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = file("C:\\Users\\chris/.ssh/id_rsa.pub") # update this with the path to your public key
}

# Create an IAM instance profile and associate it with the role
resource "aws_iam_instance_profile" "ecs_task_execution_profile" {
  name = "ecsTaskExecutionProfile"
  role = aws_iam_role.ecs_task_execution_role.name
}

# Update aws_instance block
resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "g4dn.xlarge"
  vpc_security_group_ids = [aws_security_group.allow_http_ssh.id]
  key_name               = aws_key_pair.deployer.key_name

  iam_instance_profile = aws_iam_instance_profile.ecs_task_execution_profile.name

  user_data = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get update
    apt-get install -y docker-ce awscli   # Added awscli installation here
    sleep 60    # Delay execution to allow the IAM role to take effect
    aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 277084857206.dkr.ecr.us-east-1.amazonaws.com/llm-test-image
    docker pull 277084857206.dkr.ecr.us-east-1.amazonaws.com/llm-test-image:latest
    docker run -d -p 8000:8000 277084857206.dkr.ecr.us-east-1.amazonaws.com/llm-test-image:latest
  EOF


  tags = {
    Name = "web"
  }
}


resource "aws_eip" "ip" {
  vpc      = true
  instance = aws_instance.web.id

  tags = {
    Name = "ip"
  }
}
