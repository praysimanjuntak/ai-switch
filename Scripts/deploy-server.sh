#!/bin/zsh
set -euo pipefail

# Deploys Server/ to a VPS that runs the shared Caddy ingress (~/shared-ingress,
# docker network "shared_ingress"). Usage: Scripts/deploy-server.sh [ssh-host] [domain]
PROJECT_DIR=${0:A:h:h}
HOST=${1:-vps}
DOMAIN=${2:-}
REMOTE_DIR='~/aiswitch-sync'

if [[ -z "$DOMAIN" ]]; then
    PUBLIC_IP=$(ssh "$HOST" 'curl -s -m 5 https://api.ipify.org')
    DOMAIN="aiswitch.$PUBLIC_IP.nip.io"
fi

print "Deploying to $HOST as https://$DOMAIN"
rsync -az --delete --exclude data --exclude .env --exclude node_modules \
    "$PROJECT_DIR/Server/" "$HOST:$REMOTE_DIR/"

ssh "$HOST" DOMAIN="$DOMAIN" 'bash -s' <<'REMOTE'
set -euo pipefail
cd ~/aiswitch-sync
if [[ ! -f .env ]]; then
    printf 'AISWITCH_PUSH_SECRET=%s\n' "$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-40)" > .env
    chmod 600 .env
fi
grep -q '^AISWITCH_PUBLIC_ORIGIN=' .env || printf 'AISWITCH_PUBLIC_ORIGIN=https://%s\n' "$DOMAIN" >> .env
docker compose up -d --build --remove-orphans

cd ~/shared-ingress
if ! grep -q "^$DOMAIN " Caddyfile; then
    cp Caddyfile "Caddyfile.before-aiswitch-$(date -u +%Y%m%dT%H%M%SZ)"
    sed "s/__DOMAIN__/$DOMAIN/" ~/aiswitch-sync/deploy/Caddyfile.snippet >> Caddyfile
    docker exec shared-ingress-caddy caddy reload --config /etc/caddy/Caddyfile
fi
REMOTE

for attempt in {1..30}; do
    if curl -fsS -m 10 "https://$DOMAIN/healthz" >/dev/null 2>&1; then
        print "Healthy: https://$DOMAIN/healthz"
        break
    fi
    [[ $attempt -eq 30 ]] && { print -u2 "Server did not become healthy at https://$DOMAIN"; exit 1; }
    sleep 2
done

print "Server address: https://$DOMAIN"
print "Push secret:    $(ssh "$HOST" "sed -n 's/^AISWITCH_PUSH_SECRET=//p' $REMOTE_DIR/.env")"
print "Enter both in AI Switch → Phone."
