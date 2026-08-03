#!/usr/bin/env bash
# Seeds sample divers, dive sites, and dives into a running scuba-divelog
# instance via its API.
#
# Auto-discovers BOTH the target namespace and the Traefik LB IP from the
# CURRENTLY ACTIVE kubectl context, instead of trusting a hardcoded/default
# URL or namespace — a stale default is exactly what silently re-seeded the
# wrong cluster last time.
#
# Usage:
#   ./seed-data.sh [namespace]
#
# namespace is optional — if omitted, it's auto-discovered by finding the
# scuba-divelog frontend Service on the current cluster. Pass it explicitly
# to disambiguate if the app is installed in more than one namespace.
# Requires kubectl and jq.
set -euo pipefail

CONTEXT=$(kubectl config current-context)
echo "kubectl context: $CONTEXT"

if [[ -n "${1:-}" ]]; then
  NAMESPACE="$1"
  NS_SOURCE="given"
  if ! kubectl -n "$NAMESPACE" get svc scuba-frontend >/dev/null 2>&1; then
    echo "error: no 'scuba-frontend' service in namespace '$NAMESPACE' on context '$CONTEXT'." >&2
    echo "       is scuba actually installed here? (helm list -n $NAMESPACE)" >&2
    exit 1
  fi
else
  MATCHES=()
  while IFS= read -r ns; do
    [[ -n "$ns" ]] && MATCHES+=("$ns")
  done < <(kubectl get svc -A \
    -l app.kubernetes.io/name=scuba-divelog,app.kubernetes.io/component=frontend \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}')

  if [[ ${#MATCHES[@]} -eq 0 ]]; then
    echo "error: no scuba-divelog frontend service found anywhere on context '$CONTEXT'." >&2
    echo "       is scuba actually installed here? (helm list -A)" >&2
    exit 1
  elif [[ ${#MATCHES[@]} -gt 1 ]]; then
    echo "error: found scuba-divelog installed in multiple namespaces on context '$CONTEXT':" >&2
    printf '  - %s\n' "${MATCHES[@]}" >&2
    echo "       re-run with the one you want: ./seed-data.sh <namespace>" >&2
    exit 1
  fi
  NAMESPACE="${MATCHES[0]}"
  NS_SOURCE="auto-discovered"
fi

echo "namespace:        $NAMESPACE ($NS_SOURCE)"

LB_IP=$(kubectl get svc -A -o json \
  | jq -r '[.items[] | select(.spec.type=="LoadBalancer" and (.metadata.name | test("traefik")))][0].status.loadBalancer.ingress[0].ip // empty')

if [[ -z "$LB_IP" ]]; then
  echo "error: couldn't find a traefik LoadBalancer service with an external IP on context '$CONTEXT'." >&2
  exit 1
fi

BASE_URL="https://${LB_IP}"
API="${BASE_URL}/api"
echo "resolved target:  $BASE_URL"
echo

read -r -p "Seed data into '$NAMESPACE' on '$CONTEXT' ($BASE_URL)? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "aborted."
  exit 1
fi

CURL=(curl -sk)

post() {
  local path="$1" data="$2"
  "${CURL[@]}" -X POST "$API$path" -H "Content-Type: application/json" -d "$data"
}

echo "Seeding divers..."
D1=$(post /divers '{"name":"Mara Feld","age":29,"city":"Lisbon","school":"Blue Reef Divers","cert_id":"PADI-88213","cert_level":"Advanced Open Water"}')
D2=$(post /divers '{"name":"Theo Bianchi","age":34,"city":"Genoa","school":"Mediterraneo Sub","cert_id":"SSI-40217","cert_level":"Rescue Diver"}')
D3=$(post /divers '{"name":"Priya Nair","age":26,"city":"Goa","school":"Coral Quest","cert_id":"PADI-91045","cert_level":"Divemaster"}')

D1_ID=$(jq -r '.id' <<<"$D1")
D2_ID=$(jq -r '.id' <<<"$D2")
D3_ID=$(jq -r '.id' <<<"$D3")
echo "  divers: $D1_ID $D2_ID $D3_ID"

echo "Seeding sites..."
S1=$(post /sites '{"name":"Blue Hole","city":"Dahab","country":"Egypt","typical_max_depth_m":30,"typical_visibility":"25m+","current_strength":"mild","marine_life":"reef fish, occasional reef sharks","hazards":"deep drop-off, easy to exceed planned depth"}')
S2=$(post /sites '{"name":"SS Thistlegorm","city":"Sharm El Sheikh","country":"Egypt","typical_max_depth_m":30,"typical_visibility":"15m","current_strength":"moderate","marine_life":"batfish, tuna, wreck life","hazards":"wreck penetration, strong currents"}')
S3=$(post /sites '{"name":"Manta Point","city":"Nusa Penida","country":"Indonesia","typical_max_depth_m":18,"typical_visibility":"10m","current_strength":"strong","marine_life":"manta rays","hazards":"surge, boat traffic"}')

S1_ID=$(jq -r '.id' <<<"$S1")
S2_ID=$(jq -r '.id' <<<"$S2")
S3_ID=$(jq -r '.id' <<<"$S3")
echo "  sites: $S1_ID $S2_ID $S3_ID"

echo "Seeding dives..."
post /dives "{\"date\":\"2026-06-01T09:30:00\",\"diver_id\":$D1_ID,\"site_id\":$S1_ID,\"duration_min\":42,\"max_depth_m\":28.5,\"water_temp_c\":24,\"gas_mix\":\"air\",\"tank_pressure_start_bar\":200,\"tank_pressure_end_bar\":60,\"buddy\":\"Theo Bianchi\",\"notes\":\"Great viz, saw a reef shark near the drop-off.\",\"rating\":5}" > /dev/null
post /dives "{\"date\":\"2026-06-03T10:00:00\",\"diver_id\":$D2_ID,\"site_id\":$S2_ID,\"duration_min\":50,\"max_depth_m\":29,\"water_temp_c\":25,\"gas_mix\":\"nitrox32\",\"tank_pressure_start_bar\":210,\"tank_pressure_end_bar\":70,\"buddy\":\"Mara Feld\",\"notes\":\"Wreck penetration to the cargo hold, strong current on ascent.\",\"rating\":4}" > /dev/null
post /dives "{\"date\":\"2026-06-05T08:15:00\",\"diver_id\":$D3_ID,\"site_id\":$S3_ID,\"duration_min\":38,\"max_depth_m\":16,\"water_temp_c\":26,\"gas_mix\":\"air\",\"tank_pressure_start_bar\":200,\"tank_pressure_end_bar\":80,\"buddy\":\"Mara Feld\",\"notes\":\"Three manta rays circling the cleaning station.\",\"rating\":5}" > /dev/null
post /dives "{\"date\":\"2026-06-10T09:00:00\",\"diver_id\":$D1_ID,\"site_id\":$S3_ID,\"duration_min\":40,\"max_depth_m\":17,\"water_temp_c\":25,\"gas_mix\":\"air\",\"tank_pressure_start_bar\":200,\"tank_pressure_end_bar\":55,\"buddy\":\"Priya Nair\",\"notes\":\"Strong surge, but mantas again.\",\"rating\":4}" > /dev/null
post /dives "{\"date\":\"2026-06-14T11:00:00\",\"diver_id\":$D2_ID,\"site_id\":$S1_ID,\"duration_min\":45,\"max_depth_m\":30,\"water_temp_c\":23,\"gas_mix\":\"nitrox32\",\"tank_pressure_start_bar\":210,\"tank_pressure_end_bar\":65,\"buddy\":\"Priya Nair\",\"notes\":\"Deepest dive of the trip, careful with NDL.\",\"rating\":5}" > /dev/null
post /dives "{\"date\":\"2026-06-18T09:45:00\",\"diver_id\":$D3_ID,\"site_id\":$S2_ID,\"duration_min\":48,\"max_depth_m\":27,\"water_temp_c\":24,\"gas_mix\":\"air\",\"tank_pressure_start_bar\":200,\"tank_pressure_end_bar\":58,\"buddy\":\"Theo Bianchi\",\"notes\":\"First wreck dive, loved it.\",\"rating\":5}" > /dev/null

echo "Done. Seeded 3 divers, 3 sites, 6 dives into '$NAMESPACE' on '$CONTEXT'."
echo "Verify: curl -sk $API/dives | jq"
