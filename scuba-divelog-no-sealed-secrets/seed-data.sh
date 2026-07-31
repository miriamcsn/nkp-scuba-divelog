#!/usr/bin/env bash
# Seeds sample divers, dive sites, and dives into a running scuba-divelog
# instance via its API. Requires curl and jq.
#
# Usage:
#   ./seed-data.sh [base-url]
#
# base-url defaults to https://10.55.86.149 (the it-cluster ingress IP).
set -euo pipefail

BASE_URL="${1:-https://10.55.86.149}"
API="${BASE_URL%/}/api"
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

echo "Done. Seeded 3 divers, 3 sites, 6 dives."
echo "Verify: curl -sk $API/dives | jq"
