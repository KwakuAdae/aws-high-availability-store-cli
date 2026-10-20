#!/usr/bin/env bash
# Phase 7: open the store, and prove the load balancer spreads customers across both servers.
#   ./scripts/07-open-store.sh [requests]     (default 20)
source "$(dirname "$0")/config.sh"
require ALB_DNS
COUNT="${1:-20}"
URL="http://${ALB_DNS}"

step "Your store: ${URL}"
curl -s --max-time 10 "$URL/" | grep -o '<h1>.*</h1>' | sed 's/<[^>]*>//g;s/^/   /' \
  || echo "   (not answering yet: wait a minute for health checks and DNS)"

step "${COUNT} requests: which server answered each one?"
for _ in $(seq "$COUNT"); do
  curl -s --max-time 10 "$URL/server.json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["instance_id"], d["availability_zone"])' 2>/dev/null \
    || echo "error"
done | sort | uniq -c | sed 's/^/  /'

echo ""
echo "Open ${URL} in your browser and refresh: the 'Served by' box changes between servers."
echo "(Use http://, this lab has no HTTPS certificate.)"
