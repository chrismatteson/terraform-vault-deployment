#!/bin/bash 

readonly VAULT_USER=%{ if vault_user != "" }${vault_user}%{else}"vault"%{endif}
readonly DOWNLOAD_PACKAGE_DIR="/tmp"
readonly SCRIPT_DIR="$(cd "$(dirname "$${BASH_SOURCE[0]}")" && pwd)"
readonly SYSTEM_BIN_DIR="/usr/local/bin"
readonly SCRIPT_NAME="$(basename "$0")"
readonly AWS_ASG_TAG_KEY="aws:autoscaling:groupName"
readonly CONSUL_CONFIG_FILE="default.json"
readonly VAULT_CONFIG_FILE="vault.hcl"
readonly SYSTEMD_CONFIG_PATH="/etc/systemd/system"
readonly EC2_INSTANCE_METADATA_URL="http://169.254.169.254/latest/meta-data"
readonly EC2_INSTANCE_DYNAMIC_DATA_URL="http://169.254.169.254/latest/dynamic"
readonly MAX_RETRIES=30
readonly SLEEP_BETWEEN_RETRIES_SEC=10
readonly VAULT_PATH=%{ if vault_path != "" }${vault_path}%{else}"/opt/vault"%{endif}
readonly VAULT_VERSION=%{ if vault_version != "" }${vault_version}%{ endif }
readonly VAULT_DOWNLOAD_URL=%{ if vault_download_url != "" }${vault_download_url}%{ endif }
readonly KMS_KEY=${kms_key}
readonly API_ADDR=${api_addr}
readonly CLUSTER_TAG_KEY=${cluster_tag_key}
readonly CLUSTER_TAG_VALUE=${cluster_tag_value}

function log {
  local -r level="$1"
  local -r message="$2"
  local -r timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "$${timestamp} [$${level}] [$SCRIPT_NAME] $${message}"
}

function log_info {
  local -r message="$1"
  log "INFO" "$message"
}

function log_warn {
  local -r message="$1"
  log "WARN" "$message"
}

function log_error {
  local -r message="$1"
  log "ERROR" "$message"
}

function strip_prefix {
  local -r str="$1"
  local -r prefix="$2"
  echo "$${str#$prefix}"
}

function assert_not_empty {
  local -r arg_name="$1"
  local -r arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

function assert_either_or {
  local -r arg1_name="$1"
  local -r arg1_value="$2"
  local -r arg2_name="$3"
  local -r arg2_value="$4"

  if [[ -z "$arg1_value" && -z "$arg2_value" ]]; then
    log_error "Either the value for '$arg1_name' or '$arg2_name' must be passed, both cannot be empty"
    print_usage
    exit 1
  fi
}

# A retry function that attempts to run a command a number of times and returns the output
function retry {
  local -r cmd="$1"
  local -r description="$2"
  local -r max_tries="$3"

  for i in $(seq 1 $max_tries); do
    log_info "$description"

    # The boolean operations with the exit status are there to temporarily circumvent the "set -e" at the
    # beginning of this script which exits the script immediatelly for error status while not losing the exit status code
    output=$(eval "$cmd") && exit_status=0 || exit_status=$?
    log_info "$output"
    if [[ $exit_status -eq 0 ]]; then
      echo "$output"
      return
    fi
    log_warn "$description failed. Will sleep for 10 seconds and try again."
    sleep 10
  done;

  log_error "$description failed after $max_tries attempts."
  exit $exit_status
}

function has_yum {
  [ -n "$(command -v yum)" ]
}

function has_apt_get {
  [ -n "$(command -v apt-get)" ]
}

function install_dependencies {
  log_info "Installing dependencies"

  if $(has_apt_get); then
    sudo apt-get update -y
    sudo apt-get install -y awscli curl unzip jq
  elif $(has_yum); then
    sudo yum update -y
    sudo yum install -y aws curl unzip jq
  else
    log_error "Could not find apt-get or yum. Cannot install dependencies on this OS."
    exit 1
  fi
}

function user_exists {
  local -r username="$1"
  id "$username" >/dev/null 2>&1
}

function create_user {
  local -r username="$1"

  if $(user_exists "$username"); then
    echo "User $username already exists. Will not create again."
  else
    log_info "Creating user named $username"
    sudo useradd "$username"
  fi
}

function create_consul_install_paths {
  local -r path="$1"
  local -r username="$2"

  log_info "Creating install dirs for Consul at $path"
  sudo mkdir -p "$path"
  sudo mkdir -p "$path/bin"
  sudo mkdir -p "$path/config"
  sudo mkdir -p "$path/data"
  sudo mkdir -p "$path/tls/ca"

  log_info "Changing ownership of $path to $username"
  sudo chown -R "$username:$username" "$path"
}

function fetch_binary {
  local -r product="$1"
  local -r version="$2"
  local download_url="$3"

  if [[ -z "$download_url" && -n "$version" ]];  then
    download_url="https://releases.hashicorp.com/$${product}/$${version}/$${product}_$${version}_linux_amd64.zip"
  fi

  retry \
    "curl -o '$${DOWNLOAD_PACKAGE_DIR}/$${product}.zip' '$download_url' --location --silent --fail --show-error" \
    "Downloading $${product} to $DOWNLOAD_PACKAGE_DIR" \
    5
}

function install_binary {
  local -r product="$1"
  local -r install_path="$2"
  local -r username="$3"

  local -r bin_dir="$install_path/bin"
  local -r dest_path="$bin_dir/$product"

  unzip -d /tmp "$DOWNLOAD_PACKAGE_DIR/$product.zip"

  log_info "Moving $product binary to $dest_path"
  sudo mv "/tmp/$product" "$dest_path"
  sudo chown "$username:$username" "$dest_path"
  sudo chmod a+x "$dest_path"

  local -r symlink_path="$SYSTEM_BIN_DIR/$product"
  if [[ -f "$symlink_path" ]]; then
    log_info "Symlink $symlink_path already exists. Will not add again."
  else
    log_info "Adding symlink to $consul_dest_path in $symlink_path"
    sudo ln -s "$dest_path" "$symlink_path"
  fi
}

function lookup_path_in_instance_metadata {
  local -r path="$1"
  curl --silent --show-error --location "$EC2_INSTANCE_METADATA_URL/$path/"
}

function lookup_path_in_instance_dynamic_data {
  local -r path="$1"
  curl --silent --show-error --location "$EC2_INSTANCE_DYNAMIC_DATA_URL/$path/"
}

function get_instance_ip_address {
  lookup_path_in_instance_metadata "local-ipv4"
}

function get_instance_id {
  lookup_path_in_instance_metadata "instance-id"
}

function get_instance_region {
  lookup_path_in_instance_dynamic_data "instance-identity/document" | jq -r ".region"
}

function get_peers {
  local -r cluster_tag_key="$1"
  local -r cluster_tag_value="$2"
  local -r instance_region="$3"
  local nodes=""
  nodes=$(aws ec2 describe-instances --region $instance_region --filters Name=tag:$cluster_tag_key,Values=$cluster_tag_value Name=instance-state-name,Values=pending,running | jq --raw-output '[.Reservations[].Instances[].PrivateDnsName] | .[]')
  echo $nodes
}

function get_instance_tags {
  local -r instance_id="$1"
  local -r instance_region="$2"
  local tags=""
  local count_tags=""

  log_info "Looking up tags for Instance $instance_id in $instance_region"
  for (( i=1; i<="$MAX_RETRIES"; i++ )); do
    tags=$(aws ec2 describe-tags \
      --region "$instance_region" \
      --filters "Name=resource-type,Values=instance" "Name=resource-id,Values=$${instance_id}")
    count_tags=$(echo $tags | jq -r ".Tags? | length")
    if [[ "$count_tags" -gt 0 ]]; then
      log_info "This Instance $instance_id in $instance_region has Tags."
      echo "$tags"
      return
    else
      log_warn "This Instance $instance_id in $instance_region does not have any Tags."
      log_warn "Will sleep for $SLEEP_BETWEEN_RETRIES_SEC seconds and try again."
      sleep "$SLEEP_BETWEEN_RETRIES_SEC"
    fi
  done

  log_error "Could not find Instance Tags for $instance_id in $instance_region after $MAX_RETRIES retries."
  exit 1
}

# Get the value for a specific tag from the tags JSON returned by the AWS describe-tags:
# https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-tags.html
function get_tag_value {
  local -r tags="$1"
  local -r tag_key="$2"

  echo "$tags" | jq -r ".Tags[] | select(.Key == \"$tag_key\") | .Value"
}

function assert_is_installed {
  local -r name="$1"

  if [[ ! $(command -v $${name}) ]]; then
    log_error "The binary '$name' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

function split_by_lines {
  local prefix="$1"
  shift

  for var in "$@"; do
    echo "$${prefix}$${var}"
  done
}

function generate_vault_config {
  local -r vault_dir="$1"
  local -r user="$2"
  local -r kms_key="$3"
  local -r api_addr="$4"
  local -r cluster_tag_key="$5"
  local -r cluster_tag_value="$6"
  local -r region=$(get_instance_region)
  local -r config_path="$vault_dir/config/$VAULT_CONFIG_FILE"


  local instance_id=""
  local instance_ip_address=""

  instance_id=$(get_instance_id)
  instance_ip_address=$(get_instance_ip_address)
  instance_region=$(get_instance_region)

  local retry_join_block=""
  local nodes=[]
  if [[ -z "$cluster_tag_key" || -z "$cluster_tag_value" ]]; then
    log_warn "Either the cluster tag key ($cluster_tag_key) or value ($cluster_tag_value) is empty. Will not automatically try to form a cluster based on EC2 tags."
  else
    nodes=$(get_peers $cluster_tag_key $cluster_tag_value $region)
    for node in $nodes; do
      retry_join_block="$retry_join_block
  retry_join = {leader_api_addr = \"http://$node:8200\"}"
    done;
  fi


  log_info "Creating default Vault configuration"
  local default_config_json=$(cat <<EOF
listener "tcp" {
  address                  = "0.0.0.0:8200"
  tls_disable              = "true"
  tls_disable_client_certs = "true"
}
storage "raft" {
  node_id = "$instance_id"
  path = "$vault_dir/data"
  $retry_join_block
}
seal "awskms" {
  region     = "$region"
  kms_key_id = "$kms_key"
}
api_addr = "$api_addr"
cluster_addr = "http://$instance_ip_address:8200"
ui       = true  
EOF
)
  log_info "Installing Vault config file in $config_path"
  echo "$default_config_json" > "$config_path"
  chown "$user:$user" "$config_path"
}

function generate_systemd_config {
  local -r service="$1"
  local -r systemd_config_path="$2"
  local -r user="$3"
  local -r exec_string="$4"
  local -r config_dir="$5"
  local -r config_file="$6"
  local -r bin_dir="$7"
  shift 7
  local -r config_path="$config_dir/$config_file"

  log_info "Creating systemd config file to run $service in $systemd_config_path/$service.service"

  local -r unit_config=$(cat <<EOF
[Unit]
Description="HashiCorp $service"
Documentation=https://www.hashicorp.com/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=$config_path
EOF
)
  if [[ $service == "vault" ]]; then
    local -r extra_unit_config=$(cat <<EOF
StartLimitIntervalSec=60
StartLimitBurst=3
EOF
)
  fi

  local -r service_config=$(cat <<EOF
[Service]
User=$user
Group=$user
ExecStart=$exec_string
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536
EOF
)

  if [[ $service == "vault" ]]; then
    local -r extra_service_config=$(cat <<EOF
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StartLimitInterval=60
StartLimitIntervalSec=60
StartLimitBurst=3
LimitMEMLOCK=infinity
EOF
)
fi

  local -r install_config=$(cat <<EOF
[Install]
WantedBy=multi-user.target
EOF
)

  echo -e "$unit_config" > "$systemd_config_path/$service.service"
  echo -e "$extra_unit_config" >> "$systemd_config_path/$service.service"
  echo -e "$service_config" >> "$systemd_config_path/$service.service"
  echo -e "$extra_service_config" >> "$systemd_config_path/$service.service"
  echo -e "$install_config" >> "$systemd_config_path/$service.service"
}

function main {
  log_info "Starting Vault install"
  install_dependencies
  create_user "$${VAULT_USER}"
# This should be fixed
  create_consul_install_paths "$VAULT_PATH" "$VAULT_USER"

  fetch_binary "vault" "$VAULT_VERSION" "$VAULT_DOWNLOAD_URL"
  install_binary "vault" "$VAULT_PATH" "$VAULT_USER"

  assert_is_installed "systemctl"
  assert_is_installed "aws"
  assert_is_installed "curl"
  assert_is_installed "jq"

  # If $systemd_stdout and/or $systemd_stderr are empty, we leave them empty so that generate_systemd_config will use systemd's defaults (journal and inherit, respectively)


  generate_vault_config "$VAULT_PATH" \
    "$VAULT_USER" \
    "$KMS_KEY" \
    "$API_ADDR" \
    "$CLUSTER_TAG_KEY" \
    "$CLUSTER_TAG_VALUE"

  generate_systemd_config "vault" \
    "$SYSTEMD_CONFIG_PATH" \
    "$VAULT_USER" \
    "$VAULT_PATH/bin/vault server -config=$VAULT_PATH/config/vault.hcl" \
    "$VAULT_PATH/config" \
    "vault.hcl" \
    "$VAULT_PATH/bin"
  systemctl enable vault
  service vault restart
}

main $@
