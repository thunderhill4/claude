# INSECURE: triggers TF-CMP-001
# EC2 instance with public IP

resource "aws_instance" "bastion" {
  ami                         = "ami-0c55b159cbfafe1f0"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  key_name                    = "my-key"

  tags = {
    Name = "bastion-host"
  }
}

resource "aws_instance" "app_server" {
  ami                         = "ami-0c55b159cbfafe1f0"
  instance_type               = "t3.large"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true

  tags = {
    Name = "app-server"
  }
}

# INSECURE: triggers TF-CMP-002
# Launch template with IMDSv1 enabled (http_tokens not required)

resource "aws_launch_template" "app" {
  name_prefix   = "app-"
  image_id      = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.medium"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "app-instance"
    }
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}
