# ---------- Приватні сабнети всередині дефолтного VPC ----------
# Дефолтний VPC має тільки публічні сабнети, тому додаємо два приватні (2 AZ)
# з NAT: нодам потрібен outbound для образів, SSM, ECR і завантаження gVisor —
# без публічних IP на нодах.

# Припущення: дефолтний VPC зазвичай /16. Якщо в тебе інший префікс —
# поправь netnum у cidrsubnet нижче (препроцесія: /20 → newbits=4, netnum<16).
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

# NAT живе в наявному публічному сабнеті дефолтного VPC (AZ0)
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

  # Karpenter/Auto Mode шукає сабнети за цим тегом; дублювання з кластерними
  # subnet_ids навмисне — тег не шкодить, а гіпотезу перевіримо планом.
  tags = {
    Name                                         = "${var.cluster_name}-private-${count.index}"
    "karpenter.sh/discovery/${var.cluster_name}" = "true"
  }

  lifecycle {
    precondition {
      condition     = local.vpc_prefix <= 16
      error_message = "Дефолтний VPC очікується /16 або ширше; при іншому префіксі поправ newbits/netnum у cidrsubnet."
    }
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
