# OCI Terraform Variables
# Real values for agent-coder deployment

# OCI Provider Configuration
tenancy_ocid     = "ocid1.tenancy.oc1..aaaaaaaaaivbrzvzfcodgcuxdwqcisuawi7vpvp3kt7obmdnr2aosqlug53a"
user_ocid        = "ocid1.user.oc1..aaaaaaaa5npjn7pjw6b6vnqtvtmc6h2ggboj3nr5e5ordimx6pxy46yks7yq"
fingerprint      = "5d:2c:85:d5:8f:0f:b9:60:19:5f:31:98:11:43:2e:b1"
private_key_path = "~/.oci/oci_api_key.pem"
region           = "us-ashburn-1"
compartment_id   = "ocid1.compartment.oc1..aaaaaaaauehbyd5gast7s6w65igxfjmhw5uyuwpkiox73yhzulcbh7roz3xa"

# General Configuration
name_prefix = "agent-coder"
environment = "dev"

# Network Configuration
vcn_cidr    = "10.0.0.0/16"
subnet_cidr = "10.0.1.0/24"

# Replace with your IP address (get it from https://ifconfig.me)
allowed_ssh_cidrs  = ["76.27.163.65/32"]
allowed_http_cidrs = ["76.27.163.65/32"]
extra_ports        = [3000, 3001]

# Compute Configuration
availability_domain = "fBMf:US-ASHBURN-AD-1"
instance_shape           = "VM.Standard.A1.Flex"  # ARM64 Always Free instance
instance_ocpus           = 4
instance_memory_gb       = 24
boot_volume_size_gb      = 150
workspace_volume_size_gb = 50
workspace_mount_path     = "/mnt/workspace"

# SSH public key (contents of ~/.ssh/oci_agent_coder.pub)
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7i///uMbqYyZth4kXSnX0vnJ9LE0LALwLJA2PwOla8 dirk@Dirk-Laptop"

# Application Configuration
aws_region       = "us-east-1"
ecr_registry     = "830364544979.dkr.ecr.us-east-1.amazonaws.com"
s3_bucket        = "agent-coder-workspace-830364544979"
bedrock_model_id = "anthropic.claude-3-5-sonnet-20241022-v2:0"
log_format       = "json"
app_port         = 8080
max_iterations   = 10
iteration_timeout = 300

# Logging Configuration
log_retention_days = 30

# Monitoring Configuration
alert_email = "dirk.weibel@gmail.com"
