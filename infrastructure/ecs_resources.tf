provider "aws" {
  region = "<your-region>"
}

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "my_repository" {
  name = "my-api"
}

resource "aws_ecs_cluster" "my_cluster" {
  name = "my-cluster"
}

resource "aws_ecs_task_definition" "my_task" {
  family                   = "my-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "2048"  # Corresponds to 4 vCPU in g4dn.xlarge
  memory                   = "8192"  # Corresponds to 16GB RAM in g4dn.xlarge

  container_definitions = jsonencode([{
    name      = "my-api"
    image     = "${aws_ecr_repository.my_repository.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8000
      hostPort      = 8000
    }]
  }])
}

resource "aws_ecs_service" "my_service" {
  name            = "my-service"
  cluster         = aws_ecs_cluster.my_cluster.id
  task_definition = aws_ecs_task_definition.my_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets = ["subnet-abcdef", "subnet-ghijkl"]
    assign_public_ip = true
  }
}
