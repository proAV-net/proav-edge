#!/usr/bin/env bash
# proAV.Net Edge installer.
#
#   curl -fsSL https://raw.githubusercontent.com/proAV-net/proav-edge/main/install.sh | bash
#
# or download it and run it with options:
#
#   bash install.sh [--dir DIR] [--version VERSION|next|latest] [--cloud HOST] [--api-key KEY]
#                   [--name NAME] [--password PASSWORD] [--proxy URL] [--no-https] [--yes]
#
# What it does: checks Docker, downloads docker-compose.yml and .env.example for the chosen release into DIR,
# asks the few questions the edge needs (or takes them from the options), pins the release version in .env,
# starts the stack, waits for the edge to answer, and prints the dashboard address and the certificate
# fingerprint processors pin. Safe to run again: an existing .env is kept and only missing values are asked.
set -euo pipefail

REPO="proAV-net/proav-edge"
IMAGE="ghcr.io/proav-net/proav-edge"
RAW="https://raw.githubusercontent.com/${REPO}"
API="https://api.github.com/repos/${REPO}"

DIR=""
VERSION=""
CLOUD=""
API_KEY=""
NAME=""
PASSWORD=""
PROXY=""
HTTPS=1
YES=0

usage() { sed -n '2,15p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift ;;
        --version) VERSION="$2"; shift ;;
        --cloud) CLOUD="$2"; shift ;;
        --api-key) API_KEY="$2"; shift ;;
        --name) NAME="$2"; shift ;;
        --password) PASSWORD="$2"; shift ;;
        --proxy) PROXY="$2"; shift ;;
        --no-https) HTTPS=0 ;;
        --yes|-y) YES=1 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Reads a value interactively unless --yes was given or stdin is not a terminal.
ask() { # ask VAR "Prompt" "default" [secret]
    local var="$1" prompt="$2" default="${3:-}" secret="${4:-}" value=""
    if [ "$YES" = 1 ] || [ ! -t 0 ]; then
        printf -v "$var" '%s' "$default"
        return
    fi
    if [ -n "$secret" ]; then
        read -r -s -p "$prompt${default:+ [$default]}: " value; echo
    else
        read -r -p "$prompt${default:+ [$default]}: " value
    fi
    printf -v "$var" '%s' "${value:-$default}"
}

# ---------- 1. Docker ----------
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker Engine (https://docs.docker.com/engine/install/) and run this again."
docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is missing (docker compose version failed). Install docker-compose-plugin and run this again."
docker info >/dev/null 2>&1 || die "Docker is installed but this user cannot talk to it. Run as root, or add the user to the docker group and log in again."

# ---------- 2. Where ----------
if [ -z "$DIR" ]; then
    if [ "$(id -u)" = 0 ]; then DIR=/opt/proav-edge; else DIR="$HOME/proav-edge"; fi
fi
mkdir -p "$DIR"
cd "$DIR"
say "Installing into $DIR"

# ---------- 3. Which release ----------
# A pinned version keeps `docker compose up -d` deterministic; the dashboard updates from there.
if [ -z "$VERSION" ]; then
    VERSION=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)
    if [ -z "$VERSION" ]; then
        warn "Could not read the latest release from GitHub; using the 'latest' channel tag instead."
        VERSION=latest
    fi
fi
case "$VERSION" in
    next|latest) REF=main ;;
    *) REF="$VERSION" ;;
esac
say "Release: $VERSION"

# ---------- 4. Files ----------
fetch() { # fetch PATH DEST
    curl -fsSL "$RAW/$REF/$1" -o "$2.tmp" && mv "$2.tmp" "$2"
}
fetch docker-compose.yml docker-compose.yml || die "Could not download docker-compose.yml for $VERSION from $RAW/$REF/"
if [ ! -f .env ]; then
    fetch .env.example .env || die "Could not download .env.example"
    NEW_ENV=1
else
    NEW_ENV=0
    say ".env already exists; keeping it and asking only for what is missing"
fi

# ---------- 5. Settings ----------
envget() { sed -n "s/^$1=\(.*\)$/\1/p" .env | tail -1; }
envset() { # envset KEY VALUE  (replaces the line, or appends)
    local key="$1" value="$2"
    if grep -q "^$key=" .env; then
        # Use a temp file so values with slashes or ampersands are safe.
        awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' .env > .env.tmp && mv .env.tmp .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

[ -z "$NAME" ] && NAME=$(envget EDGE_NAME)
[ -z "$NAME" ] || [ "$NAME" = "Site edge" ] && ask NAME "Name for this edge, as shown in the portal" "$(hostname -s 2>/dev/null || hostname)"
envset EDGE_NAME "$NAME"

[ -z "$CLOUD" ] && CLOUD=$(envget EDGE_CLOUD_HOST)
[ -z "$CLOUD" ] && ask CLOUD "Cloud to connect to (proav.cloud for production, test.proav.cloud for test)" "proav.cloud"
envset EDGE_CLOUD_HOST "$CLOUD"
envset EDGE_CLOUD_SECURE "true"

[ -z "$API_KEY" ] && API_KEY=$(envget EDGE_CLOUD_API_KEY)
if [ -z "$API_KEY" ]; then
    ask API_KEY "Namespace API key with the device-register capability (Portal → Settings → API keys), or blank to add it later" "" secret
fi
envset EDGE_CLOUD_API_KEY "$API_KEY"

[ -z "$PASSWORD" ] && PASSWORD=$(envget EDGE_ADMIN_PASSWORD)
if [ -z "$PASSWORD" ]; then
    GENERATED=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)
    ask PASSWORD "Dashboard password for user 'admin' (blank = generate one)" "" secret
    if [ -z "$PASSWORD" ]; then PASSWORD="$GENERATED"; GENERATED_USED=1; fi
fi
envset EDGE_ADMIN_PASSWORD "$PASSWORD"

if [ -z "$PROXY" ] && [ "$NEW_ENV" = 1 ]; then
    ask PROXY "Web proxy this site needs to reach the internet (http://host:port), or blank for a direct connection" ""
fi
if [ -n "$PROXY" ]; then
    envset EDGE_PROXY_MODE Manual
    envset EDGE_PROXY_URL "$PROXY"
fi

# Channel follows the cloud: test sites take beta builds.
case "$CLOUD" in
    test.*) envset EDGE_UPDATES_CHANNEL next ;;
    *) envset EDGE_UPDATES_CHANNEL latest ;;
esac
if [ "$HTTPS" = 1 ]; then envset EDGE_RELAY_HTTPS_PORT 8443; else envset EDGE_RELAY_HTTPS_PORT 0; fi
envset EDGE_TAG "$VERSION"
chmod 600 .env

# ---------- 6. Start ----------
say "Pulling $IMAGE:$VERSION"
docker compose pull --quiet
say "Starting the edge"
docker compose up -d

printf 'Waiting for the edge to answer'
HEALTH=""
for _ in $(seq 1 60); do
    HEALTH=$(curl -fsS -m 2 http://127.0.0.1:8090/healthz 2>/dev/null || true)
    [ -n "$HEALTH" ] && break
    printf '.'; sleep 1
done
echo
[ -n "$HEALTH" ] || { docker compose logs --tail 30 edge; die "The edge did not answer on port 8090. The log above says why."; }

# ---------- 7. Report ----------
json() { printf '%s' "$HEALTH" | sed -n "s/.*\"$1\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1; }
EDGE_VERSION=$(json version)
FINGERPRINT=$(json relayCertificateFingerprint)
IPS=$(hostname -I 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || true)
FIRST_IP=$(printf '%s' "$IPS" | awk '{print $1}')

echo
say "proAV.Net Edge ${EDGE_VERSION:-$VERSION} is running."
echo
echo "  Dashboard:   http://${FIRST_IP:-<this-host>}:8090/edge/   (user: admin)"
if [ "${GENERATED_USED:-0}" = 1 ]; then
    echo "  Password:    $PASSWORD   (generated; it is in $DIR/.env)"
fi
if [ -z "$API_KEY" ]; then
    echo "  Registration: no API key given. Add EDGE_CLOUD_API_KEY to $DIR/.env and run: docker compose up -d"
else
    echo "  Registration: the edge registers itself in the portal within a minute as \"$NAME\"."
fi
if [ -n "$PROXY" ]; then
    echo "  Proxy:       $PROXY (change it on the dashboard's Cloud tab if the test fails)"
fi
echo
if [ "$HTTPS" = 1 ] && [ -n "$FINGERPRINT" ]; then
    echo "  Point processors here over HTTPS (their config, Settings → Config on the processor dashboard):"
    echo "    { \"cloudConfig\": { \"host\": \"${FIRST_IP:-<this-host>}:8443\", \"secure\": true,"
    echo "                        \"certificateFingerprint\": \"$FINGERPRINT\" } }"
    echo "  Processors on a framework older than 2026.10.14 use plain HTTP instead:"
fi
echo "    { \"cloudConfig\": { \"host\": \"${FIRST_IP:-<this-host>}:8080\", \"secure\": false } }"
echo
echo "  Update later from the dashboard's Software tab, or: cd $DIR && docker compose pull && docker compose up -d"
