#!/bin/bash
set -eEu -o pipefail

# Script must run as group 'vyattacfg' to prevent errors and system instability
if [ "$( id -g -n )" != 'vyattacfg' ] ; then
    echo "This script must be executed from vyatta configuration system."
    exit 1
fi

ACTION=$1
INTERFACE=$2

function               vyapi { "$vyatta_sbindir/my_cli_shell_api" "$@" ; }
function node_exists { vyapi exists       interfaces wireguard "$INTERFACE" "$@" ; }
function node_value  { vyapi returnValue  interfaces wireguard "$INTERFACE" "$@" ; }
function node_values { vyapi returnValues interfaces wireguard "$INTERFACE" "$@" ; }

function cfg_address {
    # If address is deleted
    if [ "$ACTION" = DELETE ]; then
        OP=delete
    else
        OP=add

        ! ip a show dev "$INTERFACE" |
          grep -qs " inet6* $1 "
        # If already present, do not add
    fi &&
    # Execute operation on link
    sudo /opt/vyatta/sbin/vyatta-address $OP "$INTERFACE" "$1"
}
function cfg_description {
    # If description has value
    if node_exists description; then
        # Set link alias
        ip link set dev "$INTERFACE" alias "$( node_value description )"
    else
        # Remove link alias
        sudo touch tee "/sys/class/net/$INTERFACE/ifalias" </dev/null
    fi
}
function cfg_fwmark {
    # If fwmark has value
    if node_exists fwmark; then
        # Mark packets leaving this interface
        sudo wg set "$INTERFACE" fwmark $( node_value fwmark )
    else
        # Do not mark packets leaving this interface
        sudo wg set "$INTERFACE" fwmark 0
    fi
}
function cfg_listen-port {
    # If listen-port has value
    if node_exists listen-port; then
        # Set listen-port
        sudo wg set "$INTERFACE" listen-port $( node_value listen-port )
    else
        # Set listen-port to random port
        sudo wg set "$INTERFACE" listen-port 0
    fi
}
function cfg_mtu {
    # If mtu has value
    if node_exists mtu; then
        # Set link MTU
        ip link set "$INTERFACE" mtu $( node_value mtu )
    fi
}
function cfg_private-key {
    # If private-key has value
    if node_exists private-key; then
        # Create variable for private-key value
        PRIVATE_KEY=node_value private-key)
        # If private-key is a file
        if [ -f "$PRIVATE_KEY" ]; then
            # Set private-key to file
            sudo wg set "$INTERFACE" private-key $PRIVATE_KEY
        else
            # Set private-key to value
            echo $PRIVATE_KEY | sudo wg set "$INTERFACE" private-key /proc/self/fd/0
        fi
    else
        # Remove private-key
        sudo wg set "$INTERFACE" private-key /dev/null
    fi
}
function cfg_route-allowed-ips {
    # Update routing table
    /opt/wireguard/update_routes.sh "$INTERFACE"
}

## Interface option configuration
# If more than two parameters are passed to this script
if [ $# -gt 2 ]; then
    # If function exists in script, then run the function
    type "cfg_$3" 2> /dev/null |
    grep -q function &&
    eval "'cfg_$3' ${4:-}"
    # Do not process the rest of the script
    exit
fi

## Main interface configuration
# If link doesn't exist
if ! ip link show dev "$INTERFACE" &> /dev/null; then
    # Create link
    sudo ip link add dev "$INTERFACE" type wireguard
else
    # Run all configured 'down' commands
    eval "$( node_value down-command )" > /dev/null || exit 1
    # Disable link
    sudo ip link set down dev "$INTERFACE"
fi

# If interface is deleted
if [ "$ACTION" = DELETE ]; then
    # Delete link
    sudo ip link del dev "$INTERFACE"
    # Do not process the rest of the script
    exit
fi

# If disable is not set
if ! node_exists disable; then
    # Enable link
    sudo ip link set up dev "$INTERFACE"
    # Update routing table
    /opt/wireguard/update_routes.sh "$INTERFACE"
    # Run all configured 'up' commands
    eval "$( node_value up-command ) > /dev/null" || exit 1
fi
