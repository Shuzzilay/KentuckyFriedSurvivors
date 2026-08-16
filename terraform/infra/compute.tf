
data "aws_ssm_parameter" "bottlerocket_ami" {
  name = "/aws/service/bottlerocket/aws-ecs-2/x86_64/latest/image_id"
}


resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.project}-data"
    "pz:role" = "data"
  }
}


resource "aws_launch_template" "server" {
  name_prefix   = "${var.project}-"
  image_id      = data.aws_ssm_parameter.bottlerocket_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.server.id]
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.toml.tftpl", {
    cluster_name           = aws_ecs_cluster.main.name
    container_stop_timeout = var.container_stop_timeout
    bootstrap_image        = local.bootstrap_image
  }))

  block_device_mappings {
    device_name = "/dev/xvdb"
    ebs {
      volume_size           = 40
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens = "required" # Bootstrap requires IMDSv2.
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project}-server" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "server" {
  name                = "${var.project}-server"
  vpc_zone_identifier = [aws_subnet.public.id]
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1

  launch_template {
    id      = aws_launch_template.server.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "${var.project}-server"
    propagate_at_launch = true
  }
}
