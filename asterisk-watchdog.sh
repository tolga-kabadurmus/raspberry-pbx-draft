# Raspberry Pi 4 FreePBX Installation Guide

**Author:** Faik Tolga Kabadurmuş  
**Email:** ktolga@gmail.com  

## Purpose

This document primarily describes the installation and initial system preparation steps for running **FreePBX on a Raspberry Pi 4**, with a focus on Docker-based deployment, storage durability, and baseline system security.
However this document targets to make FreePbx functional on Raspberry Pi devices, some insructions in the file can be usefull for whom is searching for;
- Securing SSH connections
- Installing docker and container envrionment
- Hardening for public access devices

---

## Raspberry Pi Installation

We start by installing the operating system using **Raspberry Pi Imager**.

- Download Raspberry Pi Imager:  
  https://www.raspberrypi.com/software/

Follow the official steps to flash an OS image compatible with your Raspberry Pi architecture (32-bit or 64-bit).  
For this guide, a **minimal OS image** is preferred and recommended.

---

## System Update

Even after a fresh OS installation, system packages should be updated.

```bash
sudo su   # requires the password of the default user (e.g. pi)
apt update
apt upgrade -y
```

---

## Attaching an HDD / SSD or USB Stick for Persistent Storage

Although a 32GB SD card may be sufficient initially, it is not suitable for long-term Docker workloads due to limited capacity and wear concerns.  
Using an external HDD, SSD, or USB stick is strongly recommended.

### 1. Identify the disk device
```bash
fdisk -l
```

Identify the device path (e.g. `/dev/sda`, `/dev/sdb`).

### 2. Wipe existing partitions and create a new filesystem
Assuming the device is `/dev/sda`:

```bash
sudo wipefs -a /dev/sda
sudo mkfs -t ext4 /dev/sda2
```

### 3. Retrieve the UUID (if needed)
```bash
blkid /dev/sda
```

### 4. Create a mount point
```bash
mkdir -p /mnt/ssd
```

### 5. Configure automatic mounting at boot
Edit `/etc/fstab`:

```bash
# COMMENT: requires admin/root privileges
sudo su
echo "UUID=<YOUR_UUID_HERE> /mnt/ssd ext4 defaults,noatime 0 2" >> /etc/fstab
mount -a
```

---

## Docker Installation

### 1. Base installation
Source:  
https://pimylifeup.com/raspberry-pi-docker/

```bash
apt update
apt upgrade -y
curl -sSL https://get.docker.com | sh
reboot
```

### 2. Switch to root after reboot
```bash
sudo su
```

---

## Relocating Docker and Containerd Data Directories

Docker and containerd perform frequent I/O operations. Keeping their data on the SD card significantly reduces its lifespan.  
Therefore, we move all Docker-related data to the mounted SSD.

> NOTE: Skip this section if no external SSD/HDD is mounted.

### Docker data directory configuration

```bash
# COMMENT: stop services
systemctl stop docker
systemctl stop containerd

ps aux | grep containerd
ps aux | grep docker
```

```bash
# COMMENT: migrate Docker data directory
mkdir -p /mnt/ssd/docker-data
rsync -aHAX --numeric-ids /var/lib/docker/ /mnt/ssd/docker-data/
mkdir -p /etc/docker
vi /etc/docker/daemon.json
```

Add the following content:
```json
{
  "data-root": "/mnt/ssd/docker-data"
}
```

```bash
mv /var/lib/docker /var/lib/docker.bak
```

### Containerd data directory configuration

```bash
mkdir -p /mnt/ssd/docker-data/containerd/
rsync -aHAX --numeric-ids /var/lib/containerd/ /mnt/ssd/docker-data/containerd/
containerd config default > /etc/containerd/config.toml
vi /etc/containerd/config.toml
```

```bash
# COMMENT: update root path
# root = "/mnt/ssd/docker-data/containerd"
```

```bash
mv /var/lib/containerd /var/lib/containerd.bak
```

### Restart services

```bash
systemctl daemon-reexec
systemctl start containerd
systemctl start docker
```

### Validation

```bash
docker version
docker system info | grep Root
containerd version
```

---

## Creating a Dedicated SSH and Docker User

Using the default user (e.g. `pi`) for SSH and system management is not recommended.  
Create a new privileged user with limited scope.

```bash
# COMMENT: username example is 'tolga'
adduser tolga
usermod -aG sudo tolga
usermod -aG docker tolga
```

```bash
# COMMENT: expected output should include sudo and docker groups
groups tolga
```

---

## SSH Configuration

Changing the default SSH port and restricting access improves security.

```bash
vi /etc/ssh/sshd_config
```

Ensure the following settings:

```text
# COMMENT: change SSH port to a non-standard port
Port <CUSTOM_PORT>

# COMMENT: disable root SSH login
PermitRootLogin prohibit-password

# COMMENT: password authentication must be disabled and pubkey auth must be enabled
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no

# not to permit root access
PermitRootLogin no
PermitRootLogin prohibit-password
```

Run ssh-keygen in order to create a key pair, then 
```bash
ssh-keygen

# after creating the key pair run below and locate the public key file
ls -la cat $HOME/.ssh/id_ed25519.pub >> /home/tolga/.ssh/authorized_keys
cat $HOME/.ssh/{{path-to-public-key}}.pub >> $HOME/.ssh/authorized_keys
chmod 700 $HOME/.ssh
chmod 600 $HOME/.ssh/authorized_keys
chown -R ${whoami}:${whoami}$HOME/.ssh
```

Copy private key for ssh-clients such as putty
```bash
# copy below output to your client as text file 
# run PuttyGen and create private key 
# use that private key in putty connection settings
cat $HOME/.ssh/id_ed25519
```
Restart the SSH service:

```bash
systemctl restart ssh.service
```

---

## Access Hardening (Hardening and Risk Mitigation)

Since the FreePBX server will be exposed to the Internet, unrestricted access must be prevented.  
Only explicitly permitted clients should be allowed to access the system.  
This is a mandatory security best practice, not an optional one.

According to this approach, the following access restrictions will be applied:

a. Required FreePBX ports (these will be explained in detail in a later FreePBX installation section)  
b. SSH access is restricted to the home/internal network only in this example. You may additionally allow specific external client IPs if required.  
c. `iptables` is used as the firewall and access‑control mechanism.  
d. Firewall rules must be persisted to disk so that they are automatically restored after every reboot.  
e. **VERY IMPORTANT NOTE:** When Docker is involved, firewall rules **must** be applied to both the `INPUT` and `DOCKER-USER` chains.  
   Detailed theory about `INPUT` and `DOCKER-USER` chains can be researched separately.  
   For now, it is sufficient to know that **both chains must be configured**.

If Docker were not installed on this machine, `ufw` could have been used as an alternative firewall solution.  
However, with Docker in use, direct `iptables` management is mandatory.

---

### iptables for INPUT Chain

```bash
sudo su  # Will ask for the pi user's password
apt update
apt install iptables-persistent
```

```bash
# Reset INPUT chain (policy still ACCEPT)
iptables -P INPUT ACCEPT
# Flush INPUT chain
iptables -F INPUT

# Allow existing connections (MUST BE AT THE TOP)
iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow loopback (localhost)
iptables -I INPUT 2 -i lo -j ACCEPT

# Rate-limited ICMP (ping)
iptables -I INPUT 3 -p icmp --icmp-type echo-request -m limit --limit 1/second --limit-burst 5 -j ACCEPT

# SSH access, valid only from restricted subnets
iptables -I INPUT 4 -p tcp -s 192.168.68.0/22 --dport 3389 -j ACCEPT

# FreePBX Web UI, port on docker, valid only from restricted subnets
iptables -I INPUT 5 -p tcp -s 192.168.68.0/22 --dport 8089 -j ACCEPT

# Set default policy to DROP
iptables -P INPUT DROP

# CRITICAL CHECK: SSH (CUSTOM-SSH-PORT) MUST STILL BE ACCESSIBLE
sudo iptables -L INPUT -n -v --line-numbers
```

Example expected output:

```text
Chain INPUT (policy DROP)
 pkts bytes target     prot opt in     out     source      destination
 3134 337K ACCEPT     all  --  *      *       0.0.0.0/0   0.0.0.0/0   ctstate RELATED,ESTABLISHED
   12 2575 ACCEPT     all  --  lo     *       0.0.0.0/0   0.0.0.0/0
    1   60 ACCEPT     icmp --  *      *       0.0.0.0/0   0.0.0.0/0   icmptype 8 limit
    4  196 ACCEPT     tcp  --  *      *       0.0.0.0/0   0.0.0.0/0   tcp dpt:3389
```

#### VERY IMPORTANT NOTES
a. If your SSH connection drops and you cannot reconnect, **something is wrong**.  
   Do **not** proceed further with iptables configuration.  
   Since rules are not yet persisted, "power off and on" the Raspberry Pi will restore SSH access.

b. If you've already executed iptables rules as persistant, don't worry attach a keyboard and a monitor then connect Raspberry device natively in order to solve the issue. Flush the iptables INPUT chain with the command;
```bash
# Flush INPUT chain
iptables -F INPUT
# check for no rules
iptables -L INPUT -n -v
```

c. If SSH remains accessible, continue with the following steps:

```bash
iptables-save > /etc/iptables/rules.v4
reboot
```

---

### iptables for DOCKER-USER Chain

Reconnect via SSH and configure the `DOCKER-USER` chain:

```bash
# Flush DOCKER-USER chain
sudo iptables -F DOCKER-USER

# Allow existing connections (ALWAYS FIRST)
sudo iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# FreePBX Web UI
sudo iptables -I DOCKER-USER 2 -p tcp --dport 8089 -j ACCEPT

# Flash Operator Panel (FOP)
sudo iptables -I DOCKER-USER 3 -p tcp --dport 4445 -j ACCEPT

# SIP
sudo iptables -I DOCKER-USER 4 -p udp --dport 5060 -j ACCEPT
sudo iptables -I DOCKER-USER 5 -p udp --dport 5160 -j ACCEPT

# RTP
sudo iptables -I DOCKER-USER 6 -p udp --dport 18000:18010 -j ACCEPT

# Default deny
sudo iptables -A DOCKER-USER -j DROP
```

```bash
# Verification (SSH rule is NOT expected here)
sudo iptables -L DOCKER-USER -n -v --line-numbers
```

#### VERY IMPORTANT NOTES
- SSH connectivity must still be functional.  
- If SSH access is lost, **do not continue** and follow the above steps about power-recycling of Raspberry device.

If SSH is still available, persist the rules:

```bash
iptables-save > /etc/iptables/rules.v4
reboot
```

## Deploying freepbx docker image:

We will deploy and run the image as a container with a docker-compose environment such a sustainable manner. 
Also this document aims to keep containers always up and running after any power outages and reboots. 
In order to achieve that, system service is required to develop which controls the docker compose up command of freepbx.
Step by step;

### Downloading and running initial deployment of freepbx:

Source is [epandi/tiredofit-freepbx-arm](https://github.com/epandi/tiredofit-freepbx-arm)
If the login is successfull this subject consider is done.

1. Download docker-compose.yaml file described in [epandi/tiredofit-freepbx-arm](https://github.com/epandi/tiredofit-freepbx-arm)
```bash
mkdir -p /mnt/ssd/freepbx/epandi-asterisk-freepbx-rpi
vi docker-compose.yaml
```
2. Modify docker-compose.yaml file. In the new version of docker-compose.yaml a "nginx reverse proxy for admin panel" and "a docker network" has been added. Modified full file is below.
#### IMPORTANT: 
The compose file has restart: always in every service instance in order to keep up and running in case of any container crash. But this alone is not enough, and we will move on to creating a system service shortly.
```yaml
version: '2'

services:
  freepbx-app:
    restart: always
    container_name: freepbx-app
    image: epandi/asterisk-freepbx-arm:17.15-latest
    ports:
     #### If you aren't using a reverse proxy
      # - 8089:80
     #### If you want SSL Support and not using a reverse proxy
     #- 443:443
      - 5060:5060/udp
      - 5160:5160/udp
      - 18000-18010:18000-18010/udp
     #### Flash Operator Panel
      - 4445:4445
      # Web portlarını DIŞARI AÇMA
      # ports:  <-- YOK
    expose:
      - "80"
      - "443"
    volumes:
      - ./asterisk17/certs:/certs
      - ./asterisk17/data:/data
      - ./asterisk17/logs:/var/log
      - ./asterisk17/data/www:/var/www/html
     ### Only Enable this option below if you set DB_EMBEDDED=TRUE
      - ./asterisk17/db:/var/lib/mysql
     ### You can drop custom files overtop of the image if you have made modifications to modules/css/whatever - Use with care
     #- ./assets/custom:/assets/custom
     ### Only Enable this if you use Chan_dongle/USB modem.
     #- /dev:/dev

    environment:
      - VIRTUAL_HOST=asterisk.local
      - VIRTUAL_NETWORK=nginx-proxy
     ### If you want to connect to the SSL Enabled Container
     #- VIRTUAL_PORT=443
     #- VIRTUAL_PROTO=https
      - VIRTUAL_PORT=80
      - LETSENCRYPT_HOST=hostname.example.com
      - LETSENCRYPT_EMAIL=email@example.com

      - ZABBIX_HOSTNAME=freepbx-app

      - RTP_START=18000
      - RTP_FINISH=18100

     ## Use for External MySQL Server
      - DB_EMBEDDED=TRUE

     ### These are only necessary if DB_EMBEDDED=FALSE
     # - DB_HOST=freepbx-db
     # - DB_PORT=3306
     # - DB_NAME=asterisk
     # - DB_USER=asterisk
     # - DB_PASS=asteriskpass

     ### If you are using TLS Support for Apache to listen on 443 in the container drop them in /certs and set these:
     #- TLS_CERT=cert.pem
     #- TLS_KEY=key.pem
     ### Set your desired timezone
      - TZ='Europe/Istanbul'

    ### These final lines are for Fail2ban. If you don't want, comment and also add ENABLE_FAIL2BAN=FALSE to your environment
    cap_add:
      - NET_ADMIN
    privileged: true
    networks:
      - voip_net
      
  freepbx-proxy:
    image: nginx:alpine
    restart: always
    ports:
      - 8089:80
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - freepbx-app
    networks:
      - voip_net

networks:
  voip_net:
    driver: bridge    
```

3. Create a new file named as ... and code is below
```yaml
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://freepbx-app:80;

        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Referer           $scheme://$host$request_uri;

        proxy_redirect off;
    }
}
```

4. Run the compose file with below bash command and wait a while to be full functional. 
```bash
sudo pi
cd /mnt/ssd/freepbx/epandi-asterisk-freepbx-rpi
docker compose up
```

5. Test the page whther it's functional: http://{{IP_OF_RASPBERRY}}:8089/admin and create and admin password then login.

### Making a systemctl controled service for freepbx

For a freepbx available system after any reboot (due to power outages or anything else) the system must keep itself up and running with any user intervention. Let's make a systemctl controled service for this purpose;

1. Create a file named /etc/systemd/system/freepbx.service and write down below codes into it
```txt
[Unit]
Description=FreePBX Docker Compose Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory={{PATH_TO_DOCKER_COMPOSE_FILE}}
ExecStart=docker compose up -d
ExecStop=docker compose down

StandardOutput=append:/var/log/freepbx-compose.log
StandardError=append:/var/log/freepbx-compose.err

TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
```

2. To run the service initially
```bash
systemctl daemon-reload && systemctl enable freepbx && systemctl start freepbx
```

3. Check the docker container status. You should see freepbx-app container and it's logs
```bash
docker ps
docker logs {{freepbx-app-container-id}} | more
```

4. Test the page whther it's functional: http://{{IP_OF_RASPBERRY}}:8089/admin

5. If the page is functional, -just for test- stop the service then reboot the system. After reboot you should see the docker ps output as explained above whichever user you logged in. No need to stop the service anymore.
```bash
systemctl start freepbx
reboot
docker ps
docker logs {{freepbx-app-container-id}} | more
```

## A whatchdog (draft)

For a production grade configuration you need a watchdog which keeps checking all the system items are working properly. If any part is failed your sip-phone connection will be broken. The broken phone connection might be a nightmare. In order to overcome lets design a system with the following requirements;
1- A bash script that works as watchdog to keep checking all the system parts 
  - check for internet connection is up
  - check for docker.service is up
  - check for asterisk.service is up
  - check for asterisk docker container is up
  - check for some internal cases inside the asterisk container

Write a service file located in: 
Important: paths in below script need to changed for your configuration.
```bash
#!/usr/bin/env bash

set -euo pipefail

#############################################
#               GLOBAL CONFIG
#############################################

MAX_RETRIES=3
RETRY_SLEEP_SECONDS=10

# docker exec timeout (seconds)
DOCKER_EXEC_TIMEOUT=15

INTERNET_CHECK_URL="https://1.1.1.1"

DEFAULT_ASTERISK_SERVICE="asterisk.service"
DEFAULT_CONTAINER_NAME="asterisk-dongle"

#############################################
#               ARGUMENTS
#############################################

ASTERISK_SERVICE="${1:-$DEFAULT_ASTERISK_SERVICE}"
CONTAINER_NAME="${2:-$DEFAULT_CONTAINER_NAME}"

#############################################
#          STATE + LOG CONFIG
#############################################

WATCHDOG_DIR="/mnt/ssd/freepbx/log/asterisk/watchdog"
STATE_FILE="$WATCHDOG_DIR/state"
ALERT_TS_FILE="$WATCHDOG_DIR/last_alert_ts"
LOCAL_LOG_FILE="$WATCHDOG_DIR/watchdog.log"

COOLDOWN_SECONDS=600

mkdir -p "$WATCHDOG_DIR"

[ -f "$STATE_FILE" ] || echo "OK" > "$STATE_FILE"
[ -f "$ALERT_TS_FILE" ] || echo "0" > "$ALERT_TS_FILE"


#############################################
#               LOGGING
#############################################

journal_notify() {
    local level="$1"
    local message="$2"

    local prev_state
    prev_state=$(get_state)

    local new_state="$prev_state"

    if [[ "$level" == "ERROR" ]]; then
        new_state="CRITICAL"
    elif [[ "$level" == "OK" ]]; then
        new_state="OK"
    fi

    # Console output
    echo "[${level}] ${message}"

    # Local persistent log
    local_log "$level" "$message"

    # State transition kontrolü
    if [[ "$new_state" != "$prev_state" ]]; then

        local_log "INFO" "STATE_CHANGE ${prev_state} -> ${new_state}"

        if [[ "$new_state" == "CRITICAL" ]]; then
            if can_alert; then
                local_log "ALERT" "CRITICAL alert triggered"
                set_last_alert_ts
            else
                local_log "INFO" "Alert suppressed due to cooldown"
            fi
        fi

        if [[ "$new_state" == "OK" && "$prev_state" == "CRITICAL" ]]; then
            local_log "INFO" "RECOVERED_FROM_CRITICAL"
        fi

        set_state "$new_state"
    fi
}


#############################################
#           STATE MANAGEMENT
#############################################

get_state() {
    cat "$STATE_FILE"
}

set_state() {
    echo "$1" > "$STATE_FILE"
}

get_last_alert_ts() {
    cat "$ALERT_TS_FILE"
}

set_last_alert_ts() {
    date +%s > "$ALERT_TS_FILE"
}

can_alert() {
    local now
    now=$(date +%s)
    local last
    last=$(get_last_alert_ts)

    (( now - last > COOLDOWN_SECONDS ))
}

local_log() {
    local level="$1"
    local message="$2"
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$ts][$level] $message" >> "$LOCAL_LOG_FILE"
}



#############################################
#           GENERIC RETRY HANDLER
#############################################

retry_check() {
    local fail_message="$1"
    shift

    local attempt=1

    while (( attempt <= MAX_RETRIES )); do
        echo "[INFO] Attempt ${attempt}/${MAX_RETRIES}..."

        if "$@"; then
            echo "[OK] Check ${attempt}. retry success."
            return 0
        fi

        if (( attempt < MAX_RETRIES )); then
            echo "[WARN] Check ${attempt} fail. ${RETRY_SLEEP_SECONDS}s later give another try."
            sleep "$RETRY_SLEEP_SECONDS"
        fi

        ((attempt++))
    done

    journal_notify "ERROR" "$fail_message"
    return 1
}

#############################################
#               CHECK FUNCTIONS
#############################################

check_internet() {
    curl --silent --fail --connect-timeout 5 "$INTERNET_CHECK_URL" > /dev/null 2>&1
}

handle_internet() {
    if retry_check "Internet connection not available." check_internet; then
        echo "[OK] Internet connection available."
        return 0
    else
        return 1
    fi
}

check_docker_service() {
    systemctl is-active --quiet docker.service
}

handle_docker_service() {
    if retry_check "docker.service service inactive." check_docker_service; then
        echo "[OK] docker.service active."
        return 0
    else
        return 1
    fi
}

check_asterisk_service() {
    systemctl is-active --quiet "$ASTERISK_SERVICE"
}

handle_asterisk_service() {
    if retry_check "$ASTERISK_SERVICE service inactive." check_asterisk_service; then
        echo "[OK] $ASTERISK_SERVICE service active."
        return 0
    else
        return 1
    fi
}

check_container_running() {
    docker ps --format '{{.Names}}' | grep -w "$CONTAINER_NAME" > /dev/null 2>&1
}

handle_container() {
    if retry_check "Container $CONTAINER_NAME not working." check_container_running; then
        echo "[OK] Container $CONTAINER_NAME working."
        return 0
    else
        return 1
    fi
}

#############################################
#       PLACEHOLDER FOR CONTAINER CHECKS
#############################################
find_container_name() {

    if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
        echo "$CONTAINER_NAME"
        return 0
    else
        echo "[ERROR] Container $CONTAINER_NAME not running or not exist."
        return 1
    fi
}

exec_into_container() {
    local container="$1"
    local command="$2"

    echo "[INFO] Exec: $command"

    # exec with timeout
    if timeout "$DOCKER_EXEC_TIMEOUT" \
        docker exec "$container" bash -c "$command"; then

        echo "[OK] Command executed."
        return 0
    else
        local exit_code=$?

        if [[ $exit_code -eq 124 ]]; then
            echo "[ERROR] Command timeout (${DOCKER_EXEC_TIMEOUT}s)."
        else
            echo "[ERROR] Command failed. Exit code: $exit_code"
        fi

        return 1
    fi
}

handle_container_internal_checks() {

    local container

    container=$(find_container_name) || return 1
    echo "[OK] Container found => $container"

    # Dongle "module show like dongle"
    retry_check \
        "module show like dongle failed." \
        exec_into_container \
        "$container" \
        "asterisk -rx 'module show like dongle' | grep chan_dongle.so" \
        || return 1
		
    #  Dongle device check
    retry_check \
        "dongle show devices failed." \
        exec_into_container \
        "$container" \
        "asterisk -rx 'dongle show devices'" \
        || return 1

    # the other check cases (will be implemented later)
    # exec_into_container "$container" "asterisk -rx 'sip show peers'" || return 1
	# next;
	# dongle show version
	# dongle show devices
	# dongle show device state dongle0
	# dongle cmd dongle0 AT+CGSN
	# dongle cmd dongle0 ATZ / ATE / AT+CGSN / AT+CPIN

    echo "[OK] Container internal checks success."
    return 0
}

#############################################
#               MAIN FLOW
#############################################
concurrency_lock() {
	LOCK_FILE="/var/run/asterisk-watchdog.lock"

	exec 200>"$LOCK_FILE"
	flock -n 200 || {
		echo "Another instance is already running."
		exit 1
	}
}

main() {
	concurrency_lock || return 1

    handle_internet || return 1
    handle_docker_service || return 1
    handle_asterisk_service || return 1
    handle_container || return 1
    handle_container_internal_checks || return 1

	journal_notify "OK" "All checks passed."
	return 0
}

main
exit $?


```
2- A systemd service which runs the bash script. You may call it watchdog 
Write a service file located in: /etc/systemd/system/asterisk-watchdog.service
Important: paths in below script need to changed for your configuration.
```text
[Unit]
Description=Asterisk Watchdog Check
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/mnt/ssd/freepbx
ExecStart=/mnt/ssd/freepbx/asterisk-watchdog.sh

StandardOutput=append:/mnt/ssd/freepbx/log/asterisk/watchdog/watchdog-service.log
StandardError=append:/mnt/ssd/freepbx/log/asterisk/watchdog/watchdog-service.err

[Install]
WantedBy=multi-user.target
```

3- A systemd timer that runs the service periodically
```text
[Unit]
Description=Run Asterisk Watchdog every 60 seconds

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=1
Unit=asterisk-watchdog.service

[Install]
WantedBy=timers.target
```

4. Deploy and run the services
```bash
systemctl daemon-reload
systemctl enable asterisk-watchdog
systemctl start asterisk-watchdog
systemctl enable asterisk-watchdog.timer
systemctl start asterisk-watchdog.timer
```

