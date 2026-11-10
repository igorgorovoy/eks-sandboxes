# ---------- Private subnets inside the default VPC ----------
# The default VPC only has public subnets, so we add two private ones (2 AZs)
# with NAT: nodes need outbound for images, SSM, ECR and the gVisor download —
# without public IPs on the nodes.

# Assumption: the default VPC is usually a /16. If yours is different,
# adjust netnum in cidrsubnet below (e.g. a /20 VPC -> newbits=4, netnum<16).
locals {
  vpc_prefix = tonumber(split("/", data.aws_vpc.default.cidr_block)[1])
  subnet_ids = [for s in aws_subnet.private : s.id]
}

data "aws_vpc" "default" {
  default = true
}

data "aws_availability_zones" "available" {
  state = "available"
}

# NAT lives in an existing public subnet of the default VPC (AZ0)
data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = [data.aws_availability_zones.available.names[0]]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = tolist(data.aws_subnets.default_public.ids)[0]
  tags          = { Name = "${var.cluster_name}-nat" }
}

resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id
  tags   = { Name = "${var.cluster_name}-private" }
}

resource "aws_route" "nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = data.aws_vpc.default.id
  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = cidrsubnet(data.aws_vpc.default.cidr_block, 24 - local.vpc_prefix, 100 + count.index)

  map_public_ip_on_launch = false

  # Karpenter/Auto Mode discovers subnets by this tag; duplicating the cluster's
  # subnet_ids is intentional — the tag is harmless, and the hypothesis gets checked by plan.
  tags = {
    Name                                         = "${var.cluster_name}-private-${count.index}"
    "karpenter.sh/discovery/${var.cluster_name}" = "true"
  }

  lifecycle {
    precondition {
      condition     = local.vpc_prefix <= 16
      error_message = "The default VPC is expected to be /16 or wider; otherwise adjust newbits/netnum in cidrsubnet."
    }
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
