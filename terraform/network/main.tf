# =============================================================================
# network/main.tf
# Phase 2 & 3: VPC, Subnets, NAT Gateways, Route Tables, Security Groups
# =============================================================================

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "dr" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "vpc-${var.project_name}-dr"
    Environment = var.environment
  }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "dr" {
  vpc_id = aws_vpc.dr.id

  tags = {
    Name        = "igw-${var.project_name}-dr"
    Environment = var.environment
  }
}

# ── Public Subnets ────────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.dr.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name        = "subnet-${var.project_name}-public-${count.index + 1}"
    Tier        = "public"
    Environment = var.environment
  }
}

# ── Private App Subnets ───────────────────────────────────────────────────────
resource "aws_subnet" "app" {
  count             = length(var.app_subnet_cidrs)
  vpc_id            = aws_vpc.dr.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "subnet-${var.project_name}-app-${count.index + 1}"
    Tier        = "private-app"
    Environment = var.environment
  }
}

# ── Private DB Subnets ────────────────────────────────────────────────────────
resource "aws_subnet" "db" {
  count             = length(var.db_subnet_cidrs)
  vpc_id            = aws_vpc.dr.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "subnet-${var.project_name}-db-${count.index + 1}"
    Tier        = "private-db"
    Environment = var.environment
  }
}

# ── Elastic IPs for NAT Gateways ──────────────────────────────────────────────
resource "aws_eip" "nat" {
  count  = length(var.public_subnet_cidrs)
  domain = "vpc"

  tags = {
    Name        = "eip-nat-${var.project_name}-dr-${count.index + 1}"
    Environment = var.environment
  }
}

# ── NAT Gateways (one per AZ for HA) ─────────────────────────────────────────
resource "aws_nat_gateway" "dr" {
  count         = length(var.public_subnet_cidrs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name        = "nat-${var.project_name}-dr-${count.index + 1}"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.dr]
}

# ── Route Table: Public ───────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.dr.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dr.id
  }

  tags = {
    Name        = "rtb-${var.project_name}-public-dr"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Route Tables: Private App (one per AZ → own NAT) ─────────────────────────
resource "aws_route_table" "app" {
  count  = length(var.app_subnet_cidrs)
  vpc_id = aws_vpc.dr.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.dr[count.index].id
  }

  tags = {
    Name        = "rtb-${var.project_name}-app-dr-${count.index + 1}"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "app" {
  count          = length(aws_subnet.app)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# ── Route Table: Private DB (no internet) ────────────────────────────────────
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.dr.id

  tags = {
    Name        = "rtb-${var.project_name}-db-dr"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "db" {
  count          = length(aws_subnet.db)
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# ── Aurora DB Subnet Group ────────────────────────────────────────────────────
resource "aws_db_subnet_group" "aurora_dr" {
  name        = "${var.project_name}-dr-subnet-group"
  description = "DR Aurora MySQL subnet group"
  subnet_ids  = aws_subnet.db[*].id

  tags = {
    Name        = "${var.project_name}-dr-subnet-group"
    Environment = var.environment
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Security Groups
# ─────────────────────────────────────────────────────────────────────────────

# ── ALB Security Group ────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "sg-alb-${var.project_name}-dr"
  description = "DR Application Load Balancer"
  vpc_id      = aws_vpc.dr.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
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
    Name        = "sg-alb-${var.project_name}-dr"
    Environment = var.environment
  }
}

# ── Nginx Proxy Security Group ────────────────────────────────────────────────
resource "aws_security_group" "nginx" {
  name        = "sg-nginx-${var.project_name}-dr"
  description = "DR Nginx reverse proxy"
  vpc_id      = aws_vpc.dr.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
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
    Name        = "sg-nginx-${var.project_name}-dr"
    Environment = var.environment
  }
}

# ── App Server Security Group ─────────────────────────────────────────────────
resource "aws_security_group" "app" {
  name        = "sg-app-${var.project_name}-dr"
  description = "DR Node.js application servers"
  vpc_id      = aws_vpc.dr.id

  ingress {
    description     = "App port from Nginx"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
  }

  ingress {
    description     = "App port from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from primary VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.primary_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sg-app-${var.project_name}-dr"
    Environment = var.environment
  }
}

# ── Aurora Security Group ─────────────────────────────────────────────────────
resource "aws_security_group" "aurora" {
  name        = "sg-aurora-${var.project_name}-dr"
  description = "DR Aurora MySQL cluster"
  vpc_id      = aws_vpc.dr.id

  ingress {
    description     = "MySQL from app servers"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "MySQL from Lambda"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  ingress {
    description = "MySQL from primary VPC (replication)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.primary_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sg-aurora-${var.project_name}-dr"
    Environment = var.environment
  }
}

# ── Lambda Security Group ─────────────────────────────────────────────────────
resource "aws_security_group" "lambda" {
  name        = "sg-lambda-${var.project_name}-dr"
  description = "DR Lambda functions in VPC"
  vpc_id      = aws_vpc.dr.id

  egress {
    description = "HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "MySQL to Aurora"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.aurora.id]
  }

  egress {
    description     = "App port to EC2"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = {
    Name        = "sg-lambda-${var.project_name}-dr"
    Environment = var.environment
  }
}
