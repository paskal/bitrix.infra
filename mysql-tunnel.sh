#!/bin/sh
# MySQL tunnel via SSH socket forwarding to favor-group server
# Usage:
#   mysql-tunnel.sh start   # Start tunnel
#   mysql-tunnel.sh stop    # Stop tunnel
#   mysql-tunnel.sh status  # Check tunnel status
#
# Note: Use 'fgmysql' for database access - it manages the tunnel automatically

SOCKET_DIR="/tmp/mysql-tunnel"
LOCAL_SOCKET="$SOCKET_DIR/mysqld.sock"
REMOTE_SOCKET="/web/private/mysqld/mysqld.sock"
SSH_HOST="${SSH_HOST:-bitrix}"
PID_FILE="$SOCKET_DIR/tunnel.pid"

# Test if socket is responding (macOS nc -z doesn't work with Unix sockets)
socket_alive() {
    [ -S "$LOCAL_SOCKET" ] && printf '' | nc -U -w 1 "$LOCAL_SOCKET" >/dev/null 2>&1
}

# Kill any existing tunnel processes for this socket
kill_stale_tunnels() {
    pkill -f "ssh.*-N.*$LOCAL_SOCKET" 2>/dev/null || true
    rm -f "$LOCAL_SOCKET" "$PID_FILE"
}

start_tunnel() {
    # Check if tunnel already exists and works
    if socket_alive; then
        echo "Tunnel already running at $LOCAL_SOCKET"
        return 0
    fi

    # Kill ALL existing tunnel processes before starting a new one
    kill_stale_tunnels

    mkdir -p "$SOCKET_DIR"

    # Start SSH tunnel
    ssh -f -N -L "$LOCAL_SOCKET:$REMOTE_SOCKET" "$SSH_HOST"

    # Save PID of the SSH tunnel process
    pgrep -n -f "ssh.*-N.*$LOCAL_SOCKET" > "$PID_FILE" 2>/dev/null || true

    # Wait for socket to be created
    i=0
    while [ $i -lt 10 ]; do
        if [ -S "$LOCAL_SOCKET" ]; then
            echo "MySQL tunnel started at $LOCAL_SOCKET"
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done

    echo "Failed to start tunnel"
    return 1
}

stop_tunnel() {
    kill_stale_tunnels
    echo "Tunnel stopped"
}

status() {
    if socket_alive; then
        echo "Tunnel is running at $LOCAL_SOCKET"
        if [ -f "$PID_FILE" ]; then
            echo "PID: $(cat "$PID_FILE")"
        fi
        return 0
    else
        echo "Tunnel is not running"
        return 1
    fi
}

case "${1:-}" in
    start)
        start_tunnel
        ;;
    stop)
        stop_tunnel
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        echo ""
        echo "For database access, use 'fgmysql' which manages the tunnel automatically"
        exit 1
        ;;
esac
