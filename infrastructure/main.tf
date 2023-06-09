provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_subnet" "subnet1" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.subnet1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "subnet2" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24"
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.subnet2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "allow_http" {
  name        = "allow_http"
  description = "Allow inbound traffic on port 8000"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 8000
    to_port     = 8000
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

resource "aws_security_group" "allow_alb_http" {
  name        = "allow_alb_http"
  description = "Allow inbound traffic on port 80"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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

data "aws_iam_policy_document" "ecs_task_execution_role" {
  statement {
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["*"]
  }
}

data "aws_iam_policy_document" "ecs_task_execution_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json
}

resource "aws_iam_role_policy" "ecs_task_execution_policy" {
  name   = "ecsTaskExecutionPolicy"
  role   = aws_iam_role.ecs_task_execution_role.id
  policy = data.aws_iam_policy_document.ecs_task_execution_role.json
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
      "ecr:DescribeImages"
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ecs_task_execution_role.arn]
    }
  }
}

resource "aws_ecr_repository_policy" "ecr_policy" {
  repository = data.aws_ecr_repository.llm_test_image.name
  policy     = data.aws_iam_policy_document.ecr_policy.json
}


# IAM role for the EC2 instances.
data "aws_iam_policy_document" "ecs_instance_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_instance_role" {
  name               = "ecsInstanceRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_instance_role.json
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecsInstanceProfile"
  role = aws_iam_role.ecs_instance_role.name
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy_attachment" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Launch template for g4dn.xlarge instances.
resource "aws_launch_template" "lt" {
  name_prefix   = "lt"
  image_id      = "ami-0695f2f761eeb04e6" # Replace with an appropriate AMI for your region
  instance_type = "g4dn.xlarge"
  key_name      = "llm_key" # Replace with your key pair name
  
  user_data = base64encode(<<USERDATA
  #!/bin/bash
  echo ECS_CLUSTER=${aws_ecs_cluster.my_cluster.name} >> /etc/ecs/ecs.config
  USERDATA
  )

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.allow_http.id]
  }
}


# EC2 autoscaling group that utilizes the launch template.
resource "aws_autoscaling_group" "asg" {
  desired_capacity     = 1
  max_size             = 2
  min_size             = 1
  health_check_grace_period = 300
  health_check_type = "ELB"
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  vpc_zone_identifier = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
}

# ECS capacity provider.
resource "aws_ecs_capacity_provider" "cp" {
  name = "my-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.asg.arn

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 100
    }

    managed_termination_protection = "ENABLED"
  }
}

# ECS cluster with capacity provider.
resource "aws_ecs_cluster" "my_cluster" {
  name = "my-cluster"

  capacity_providers = [aws_ecs_capacity_provider.cp.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.cp.name
  }
}

resource "aws_ecs_task_definition" "my_task" {
  family                   = "my-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = "4096" 
  memory                   = "16384"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([{
    name      = "my-api"
    image     = "${data.aws_ecr_repository.llm_test_image.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8000
      hostPort      = 8000
    }]
  }])
}

resource "aws_alb" "my_alb" {
  name               = "my-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_alb_http.id]
  subnets            = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
}

resource "aws_alb_target_group" "my_target_group" {
  name     = "my-target-group"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_alb_listener" "my_listener" {
  load_balancer_arn = aws_alb.my_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.my_target_group.arn
  }
}

resource "aws_ecs_service" "my_service" {
  name            = "my-service"
  cluster         = aws_ecs_cluster.my_cluster.id
  task_definition = aws_ecs_task_definition.my_task.arn
  desired_count   = 1
  launch_type     = "EC2"

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.cp.name
  }

  network_configuration {
    subnets          = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
    security_groups  = [aws_security_group.allow_http.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.my_target_group.arn
    container_name   = "my-api"
    container_port   = 8000
  }

  depends_on = [
    aws_alb_listener.my_listener
  ]
}
