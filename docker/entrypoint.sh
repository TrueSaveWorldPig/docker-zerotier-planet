#!/bin/sh

set -e

# Configuration paths and ports
ZEROTIER_PATH="/var/lib/zerotier-one"
APP_PATH="/app"
CONFIG_PATH="${APP_PATH}/config"
BACKUP_PATH="/bak"
ZTNCUI_PATH="${APP_PATH}/ztncui"
ZTNCUI_SRC_PATH="${ZTNCUI_PATH}/src"

# Log function for consistent output
log() {
    printf "[$(date +'%Y-%m-%dT%H:%M:%S%z')] %s\n" "$*"
}

# Start ZeroTier and ztncui services
start_services() {
    log "Starting ztncui and ZeroTier..."
    
    ZT_PORT_FILE="${CONFIG_PATH}/zerotier-one.port"
    if [ ! -f "$ZT_PORT_FILE" ]; then
        echo "${ZT_PORT}" > "$ZT_PORT_FILE"
    fi
    
    cd "$ZEROTIER_PATH"
    ./zerotier-one -p$(cat "$ZT_PORT_FILE") -d
    
    log "Starting HTTP server for planet files..."
    nohup node "${APP_PATH}/http_server.js" > "${APP_PATH}/server.log" 2>&1 & 
    
    cd "$ZTNCUI_SRC_PATH"
    log "Starting ztncui..."
    npm start
}

# Ensure file server port is configured
setup_file_server() {
    FILE_SERVER_PORT_FILE="${CONFIG_PATH}/file_server.port"
    if [ ! -f "$FILE_SERVER_PORT_FILE" ]; then
        log "Generating file_server.port"
        echo "${FILE_SERVER_PORT}" > "$FILE_SERVER_PORT_FILE"
    else
        FILE_SERVER_PORT=$(cat "$FILE_SERVER_PORT_FILE")
    fi
    log "File server port: ${FILE_SERVER_PORT}"
}

# Initialize ZeroTier data from backup
init_zerotier_data() {
    log "Initializing ZeroTier data..."
    echo "${ZT_PORT}" > "${CONFIG_PATH}/zerotier-one.port"
    cp -r "${BACKUP_PATH}/zerotier-one/"* "$ZEROTIER_PATH"

    cd "$ZEROTIER_PATH"
    openssl rand -hex 16 > authtoken.secret
    ./zerotier-idtool generate identity.secret identity.public
    ./zerotier-idtool initmoon identity.public > moon.json

    IP_ADDR4=${IP_ADDR4:-$(curl -s --max-time 5 https://ipv4.icanhazip.com/ || true)}
    IP_ADDR6=${IP_ADDR6:-$(curl -s --max-time 5 https://ipv6.icanhazip.com/ || true)}

    log "Public IPv4: $IP_ADDR4"
    log "Public IPv6: $IP_ADDR6"
    
    CURRENT_ZT_PORT=$(cat "${CONFIG_PATH}/zerotier-one.port")

    if [ -n "$IP_ADDR4" ] && [ -n "$IP_ADDR6" ]; then
        stableEndpoints="[\"$IP_ADDR4/${CURRENT_ZT_PORT}\",\"$IP_ADDR6/${CURRENT_ZT_PORT}\"]"
    elif [ -n "$IP_ADDR4" ]; then
        stableEndpoints="[\"$IP_ADDR4/${CURRENT_ZT_PORT}\"]"
    elif [ -n "$IP_ADDR6" ]; then
        stableEndpoints="[\"$IP_ADDR6/${CURRENT_ZT_PORT}\"]"
    else
        log "Error: Could not determine public IP address!"
        exit 1
    fi

    echo "$IP_ADDR4" > "${CONFIG_PATH}/ip_addr4"
    echo "$IP_ADDR6" > "${CONFIG_PATH}/ip_addr6"
    log "Stable Endpoints: $stableEndpoints"

    jq --argjson newEndpoints "$stableEndpoints" '.roots[0].stableEndpoints = $newEndpoints' moon.json > temp.json && mv temp.json moon.json
    ./zerotier-idtool genmoon moon.json && mkdir -p moons.d && cp ./*.moon ./moons.d

    ./mkworld
    if [ $? -ne 0 ]; then
        log "Error: mkworld failed!"
        exit 1
    fi

    mkdir -p "${APP_PATH}/dist/"
    mv world.bin "${APP_PATH}/dist/planet"
    cp *.moon "${APP_PATH}/dist/"
    log "ZeroTier data initialization complete."
}

# Check and initialize ZeroTier
check_zerotier() {
    mkdir -p "$ZEROTIER_PATH"
    if [ -z "$(ls -A "$ZEROTIER_PATH")" ]; then
        init_zerotier_data
    else
        log "ZeroTier data already exists, skipping initialization."
    fi
}

# Initialize ztncui data from backup
init_ztncui_data() {
    log "Initializing ztncui data..."
    cp -r "${BACKUP_PATH}/ztncui/"* "$ZTNCUI_PATH"

    mkdir -p "${CONFIG_PATH}"
    echo "${API_PORT}" > "${CONFIG_PATH}/ztncui.port"
    
    cd "$ZTNCUI_SRC_PATH"
    cat > .env <<EOF
HTTP_PORT=${API_PORT}
NODE_ENV=production
HTTP_ALL_INTERFACES=true
ZT_ADDR=localhost:$(cat "${CONFIG_PATH}/zerotier-one.port")
ZT_TOKEN=$(cat "${ZEROTIER_PATH}/authtoken.secret")
EOF
    
    cp etc/default.passwd etc/passwd
    log "ztncui initialization complete."
}

# Check and initialize ztncui
check_ztncui() {
    mkdir -p "$ZTNCUI_PATH"
    if [ -z "$(ls -A "$ZTNCUI_PATH")" ]; then
        init_ztncui_data
    else
        log "ztncui data already exists, skipping initialization."
        # Update .env in case ports changed
        cd "$ZTNCUI_SRC_PATH"
        sed -i "s/^HTTP_PORT=.*/HTTP_PORT=${API_PORT}/" .env || true
    fi
}

# Main execution
setup_file_server
check_zerotier
check_ztncui
start_services
