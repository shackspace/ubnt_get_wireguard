#!/bin/bash

set -Eeuo pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap cleanup EXIT
function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  cleanup
  exit $EXIT
}
function warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "$FLAG $REASON"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "$FLAG $REASON"
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT" | log
}
function log() {
  while read TEXT; do
    local LOG_PATH=/tmp/`basename "${0%.*}"`.log
    if [ ! -f $LOG_PATH ]; then
      sg vyattacfg -c "touch $LOG_PATH"
      chmod 664 $LOG_PATH
    fi
    local LOG_MAX_LINES=10000
    if [ -f $LOG_PATH ] && [ $(wc -l $LOG_PATH | cut -f1 -d' ') -ge $LOG_MAX_LINES ]; then
      local LOG=$(cat $LOG_PATH)
      tail -n $(($LOG_MAX_LINES-1)) > $LOG_PATH <<<$LOG
    fi
    local TIMESTAMP=$(date '+%FT%T%z')
    local REGEX='\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]'
    echo -e "$TEXT" | tee -a >(
      sed -r "s/^/$TIMESTAMP: /; s/$REGEX//g" >> $LOG_PATH
    )
  done
}
function cleanup() {
  vyatta_cfg_session && vyatta_cfg_teardown
  rm -rf $TEMP_DIR
}
function vyatta_cfg_session() {
  $VYATTA_API inSession
  return $?
}
function vyatta_cfg_setup() {
  $VYATTA_API setupSession
  if ! vyatta_cfg_session; then
    die "Failure occured while setting up vyatta configuration session."
  fi
}
function vyatta_cfg_teardown() {
  if ! $($VYATTA_API teardownSession); then
    die "Failure occured while tearing down vyatta configuration session."
  fi
}
OVERRIDE_VERSION=${1:-}
[[ $EUID -ne 0 ]] && SUDO='sudo'
SUDO=${SUDO:-}
TEMP_DIR=$(mktemp -d)
RUNNING_CONFIG_BACKUP_PATH=${TEMP_DIR}/config.run
VYATTA_SBIN=/opt/vyatta/sbin
VYATTA_API=${VYATTA_SBIN}/my_cli_shell_api
VYATTA_SET=${VYATTA_SBIN}/my_set
VYATTA_DELETE=${VYATTA_SBIN}/my_delete
VYATTA_COMMIT=${VYATTA_SBIN}/my_commit
VYATTA_SESSION=$(cli-shell-api getSessionEnv $$)
eval $VYATTA_SESSION

# Get board type
BOARD=$(
  cat /proc/cpuinfo | \
  grep 'system type' | \
  awk -F ': ' '{print tolower($2)}' | \
  sed 's/ubnt_//'
)
[ -z $BOARD ] && die "Unable to get board type."

# Change board type to match repo mapping
case $BOARD in
  e120)  BOARD='ugw3';;
  e221)  BOARD='ugw4';;
  e1020) BOARD='ugwxg';;
esac
info "Board type detected: $BOARD"

# Get firmware version
FIRMWARE=$(
  cat /opt/vyatta/etc/version | \
  awk '{print $2}'
)
info "Firmware version: $FIRMWARE"

# Get installed WireGuard version
INSTALLED_VERSION=$(dpkg-query --show --showformat='${Version}' wireguard 2> /dev/null)
info "Installed WireGuard version: $INSTALLED_VERSION"

# Get list of releases
GITHUB_API='https://api.github.com'
GITHUB_REPO='Lochnair/vyatta-wireguard'
GITHUB_RELEASES_URL="${GITHUB_API}/repos/${GITHUB_REPO}/releases"
GITHUB_RELEASES=$(curl --silent $GITHUB_RELEASES_URL)

# Get release version
RELEASE_VERSION=${OVERRIDE_VERSION:-}
if [ ! -z $RELEASE_VERSION ]; then
  GITHUB_RELEASE=$(jq '.[] | select(.tag_name == "'${RELEASE_VERSION}'")' <<< $GITHUB_RELEASES)
else
  GITHUB_RELEASE=$(jq '[.[]][0]' <<< $GITHUB_RELEASES)
  RELEASE_VERSION=$(jq -r '.tag_name' <<< $GITHUB_RELEASE)
fi
info "Release version: $RELEASE_VERSION"

# Check if override is not present and release version is newer than installed
if [ -z $OVERRIDE_VERSION ] && $(dpkg --compare-versions "$RELEASE_VERSION" 'le' "$INSTALLED_VERSION"); then
  msg "Your installation is up to date."
  exit 0
fi

# Get debian package URL
GITHUB_RELEASE_ASSETS=$(
  jq '.assets[] | select(.name | contains("'${BOARD}'-"))' <<< $GITHUB_RELEASE
)
case $(cut -d'.' -f1 <<< $FIRMWARE) in
  v2) GITHUB_RELEASE_ASSET=$(jq 'select(.name | contains("v2"))' <<< $GITHUB_RELEASE_ASSETS);;
  v1) GITHUB_RELEASE_ASSET=$(jq 'select(.name | contains("v2") | not)' <<< $GITHUB_RELEASE_ASSETS);;
  *) die "Unable to proceed with your firmware.";;
esac
DEB_URL=$(jq -r '.browser_download_url' <<< $GITHUB_RELEASE_ASSET)
[ -z $DEB_URL ] && die "Failed to locate debian package for your board and firmware."
info "Debian package URL: $DEB_URL"

# Download the package
msg 'Downloading WireGuard package...'
DEB_PATH=${TEMP_DIR}/$(jq -r '.name' <<< $GITHUB_RELEASE_ASSET)
curl --silent --location $DEB_URL -o $DEB_PATH || \
  die "Failure downloading debian package."

# Check package integrity
msg 'Checking WireGuard package integrity...'
dpkg-deb --info $DEB_PATH &> /dev/null || \
  die "Debian package integrity check failed for package."

# If WireGuard configuration exists
if $($VYATTA_API existsActive interfaces wireguard); then
  # Backup running configuration
  msg 'Backing up running configuration...'
  $VYATTA_API showConfig --show-active-only > $RUNNING_CONFIG_BACKUP_PATH

  # Remove running WireGuard configuration
  msg 'Removing running WireGuard configuration...'
  vyatta_cfg_setup
  INTERFACES=( $($VYATTA_API listNodes interfaces wireguard | sed "s/'//g") )
  for INTERFACE in $INTERFACES; do
    if [ "$($VYATTA_API returnValue interfaces wireguard $INTERFACE route-allowed-ips)" == "true" ]; then
      $VYATTA_SET interfaces wireguard $INTERFACE route-allowed-ips false
      $VYATTA_COMMIT
    fi
    INTERFACE_ADDRESSES=( $(ip -oneline address show dev $INTERFACE | awk '{print $4}') )
    for IP in $($VYATTA_API returnValues interfaces wireguard $INTERFACE address | sed "s/'//g"); do
      [[ $IP != "${INTERFACE_ADDRESSES[@]}" ]] && ip address add $IP dev $INTERFACE
    done
  done
  $VYATTA_DELETE interfaces wireguard
  $VYATTA_COMMIT
  vyatta_cfg_teardown
fi

# If WireGuard module is loaded
if $(lsmod | grep wireguard > /dev/null); then
  # Remove WireGuard module
  msg 'Removing WireGuard module...'
  $SUDO modprobe --remove wireguard || \
    die "A problem occured while removing WireGuard mdoule."
fi

# Install WireGuard package
msg 'Installing WireGuard...'
$SUDO dpkg -i $DEB_PATH &> /dev/null || \
  die "A problem occured while installing the package."

# If WireGuard was previously installed
if [ -f $RUNNING_CONFIG_BACKUP_PATH ]; then
  # Load backup configuration
  msg 'Retoring previous running configuration...'
  vyatta_cfg_setup
  $VYATTA_API loadFile $RUNNING_CONFIG_BACKUP_PATH
  $VYATTA_COMMIT
  vyatta_cfg_teardown
fi

# Move package to firstboot path to automatically install package after firmware update
msg 'Enabling WireGuard installation after firmware update...'
FIRSTBOOT_DIR='/config/data/firstboot/install-packages'
if [ ! -d $FIRSTBOOT_DIR ]; then
  $SUDO mkdir -p $FIRSTBOOT_DIR &> /dev/null || \
    die "Failure creating '$FIRSTBOOT_DIR' directory."
fi
$SUDO mv $DEB_PATH ${FIRSTBOOT_DIR}/wireguard.deb || \
  warn "Failure moving debian package to firstboot path."

msg 'WireGuard has been successfully installed.'