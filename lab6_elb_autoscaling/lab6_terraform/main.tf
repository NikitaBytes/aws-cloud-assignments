terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Доступные AZ (берём первые две, чтобы в них раскидать подсети)
data "aws_availability_zones" "available" {
  state = "available"
}

# Берём свежий Amazon Linux 2 от Amazon (для Launch Template)
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Локальные данные (AZ + user_data скрипт)
locals {
  # Первые 2 AZ в регионе
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Скрипт, который установит nginx и выведет instance-id
  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install nginx1 -y
    systemctl enable nginx
    systemctl start nginx

    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    echo "<h1>Lab 6 Nginx - instance: $INSTANCE_ID</h1>" > /usr/share/nginx/html/index.html
  EOF
}

# -------------------------
# СЕТЬ: VPC, сабсети, IGW, NAT, route tables
# -------------------------

resource "aws_vpc" "lab6" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "lab6-vpc"
  }
}

resource "aws_internet_gateway" "lab6" {
  vpc_id = aws_vpc.lab6.id

  tags = {
    Name = "lab6-igw"
  }
}

# Публичные подсети (2 шт, по одной в каждой AZ)
resource "aws_subnet" "public" {
  for_each = {
    for idx, cidr in var.public_subnet_cidrs :
    idx => {
      cidr = cidr
      az   = local.azs[idx]
    }
  }

  vpc_id                  = aws_vpc.lab6.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name = "lab6-public-${each.value.az}"
  }
}

# Приватные подсети (2 шт)
resource "aws_subnet" "private" {
  for_each = {
    for idx, cidr in var.private_subnet_cidrs :
    idx => {
      cidr = cidr
      az   = local.azs[idx]
    }
  }

  vpc_id                  = aws_vpc.lab6.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = "lab6-private-${each.value.az}"
  }
}

# EIP для NAT
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "lab6-nat-eip"
  }
}

# NAT-шлюз в первой публичной подсети
resource "aws_nat_gateway" "lab6" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id

  tags = {
    Name = "lab6-nat-gw"
  }

  depends_on = [aws_internet_gateway.lab6]
}

# Route table для публичных подсетей (0.0.0.0/0 → IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab6.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab6.id
  }

  tags = {
    Name = "lab6-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Route table для приватных подсетей (0.0.0.0/0 → NAT)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab6.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab6.id
  }

  tags = {
    Name = "lab6-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# -------------------------
# SECURITY GROUPS
# -------------------------

# SG для ALB (HTTP снаружи)
resource "aws_security_group" "alb" {
  name        = "lab6-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.lab6.id

  ingress {
    description = "HTTP from anywhere"
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

  tags = {
    Name = "lab6-alb-sg"
  }
}

# SG для EC2-инстансов в ASG:
#  - HTTP только от ALB
#  - SSH от твоего IP/сети
resource "aws_security_group" "ec2" {
  name        = "lab6-ec2-sg"
  description = "Security group for web instances"
  vpc_id      = aws_vpc.lab6.id

  ingress {
    description = "HTTP from ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"

    security_groups = [
      aws_security_group.alb.id
    ]
  }

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab6-ec2-sg"
  }
}

# -------------------------
# TARGET GROUP + ALB
# -------------------------

resource "aws_lb_target_group" "lab6" {
  name        = "lab6-target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.lab6.id

  health_check {
    enabled             = true
    interval            = 30
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "lab6-target-group"
  }
}

resource "aws_lb" "lab6" {
  name               = "lab6-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = {
    Name = "lab6-alb"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.lab6.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lab6.arn
  }
}

# -------------------------
# LAUNCH TEMPLATE (nginx + detailed monitoring)
# -------------------------

resource "aws_launch_template" "lab6" {
  name_prefix   = "lab6-launch-template-"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  vpc_security_group_ids = [aws_security_group.ec2.id]

  monitoring {
    enabled = true # Detailed CloudWatch monitoring
  }

  user_data = base64encode(local.user_data)

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "lab6-asg-instance"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name = "lab6-asg-volume"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -------------------------
# AUTO SCALING GROUP + POLICY
# -------------------------

resource "aws_autoscaling_group" "lab6" {
  name                      = "lab6-asg"
  max_size                  = 4
  min_size                  = 2
  desired_capacity          = 2
  vpc_zone_identifier       = [for s in aws_subnet.private : s.id]
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.lab6.id
    version = "$Latest"
  }

  # Подключаем к Target Group ALB
  target_group_arns = [aws_lb_target_group.lab6.arn]

  # Включаем сбор метрик группы (как в задании)
  metrics_granularity = "1Minute"
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances",
  ]

  tag {
    key                 = "Name"
    value               = "lab6-asg-instance"
    propagate_at_launch = true
  }

  # Сначала создаём новые инстансы, потом гасим старые (на случай изменений)
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_lb_listener.http]
}

# Target tracking по CPU = 50% с warm-up = 60s
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "lab6-cpu-50-target"
  autoscaling_group_name = aws_autoscaling_group.lab6.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0
  }

  # Время "прогрева" инстанса, когда его метрики ещё не учитываются
  estimated_instance_warmup = 60
}