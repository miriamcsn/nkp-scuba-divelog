#!/usr/bin/env bash
# Seed the scuba MySQL database (v3 sealed secrets namespace) with demo data:
#   5 dive sites, 5 divers, 5 dives
#
# Usage:
#   export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
#   ./scripts/seed-scuba-v3.sh

set -e

NAMESPACE="${NAMESPACE:-miriam-scuba-sealed}"
POD="${POD:-scuba-mysql-0}"
DB="${DB:-divelog}"
ROOT_PW="${ROOT_PW:-rootpw}"

echo "Seeding ${DB} in ${NAMESPACE}/${POD}..."

kubectl exec -i "${POD}" -n "${NAMESPACE}" -- \
  mysql -uroot -p"${ROOT_PW}" "${DB}" <<'SQL'

-- Wipe existing demo data (idempotent re-runs)
DELETE FROM dive;
DELETE FROM diver;
DELETE FROM site;

ALTER TABLE site  AUTO_INCREMENT = 1;
ALTER TABLE diver AUTO_INCREMENT = 1;
ALTER TABLE dive  AUTO_INCREMENT = 1;

-- 5 dive sites
INSERT INTO site
  (name, city, country, typical_max_depth_m, typical_visibility, current_strength, marine_life, hazards)
VALUES
  ('Blue Hole',         'Dahab',          'Egypt',        100, '30m',  'mild',     'reef fish, fusiliers, occasional reef shark',    'deep arch, narcosis risk'),
  ('SS Yongala',        'Townsville',     'Australia',     30, '15m',  'strong',   'bull sharks, sea snakes, giant grouper',          'strong current, deep wreck'),
  ('Silfra Fissure',    'Thingvellir',    'Iceland',       18, '100m', 'minimal',  'sparse — clarity is the attraction',              'cold water (2C), drysuit required'),
  ('Richelieu Rock',    'Surin Islands',  'Thailand',      35, '20m',  'moderate', 'whale sharks, mantas, seahorses, ghost pipefish', 'seasonal currents, liveaboard only'),
  ('Barracuda Point',   'Sipadan',        'Malaysia',      60, '25m',  'strong',   'barracuda tornado, hammerheads, turtles',         'strong downwellings, permit required');

-- 5 divers
INSERT INTO diver
  (name, age, city, school, cert_id, cert_level)
VALUES
  ('Miriam Gorino',      32, 'Sao Paulo',   'PADI Brazil', 'PADI-998877', 'Rescue Diver'),
  ('Jacques Cousteau',   56, 'Saint-Andre', 'PADI France', 'PADI-000001', 'Master Scuba Diver'),
  ('Sylvia Earle',       45, 'Gibbstown',   'PADI USA',    'PADI-123456', 'Divemaster'),
  ('Fabien Cousteau',    38, 'New York',    'PADI USA',    'PADI-000002', 'Divemaster'),
  ('Valerie Taylor',     62, 'Sydney',      'PADI Australia', 'PADI-777001', 'Master Scuba Diver');

-- 5 dives
INSERT INTO dive
  (date, diver_id, site_id, duration_min, max_depth_m, water_temp_c, gas_mix, tank_pressure_start_bar, tank_pressure_end_bar, buddy, notes, rating)
VALUES
  ('2026-05-20 09:30:00', 1, 1, 38, 42.5, 24.0, 'Air',       210, 60, 'Cousteau',  'Reached the arch. Visibility ~30m. Fusiliers everywhere.',              5),
  ('2026-05-21 11:00:00', 2, 2, 45, 28.0, 22.5, 'Nitrox32',  220, 80, 'Earle',     'Bull sharks circling the bow. Strong current — held the line.',         5),
  ('2026-05-22 13:15:00', 1, 3, 60, 12.0,  2.0, 'Air',       230, 90, 'Solo',      'Crystal clear glacial water. Drysuit dive. Surreal.',                   4),
  ('2026-05-23 08:00:00', 4, 4, 55, 30.0, 28.0, 'Nitrox32',  215, 75, 'V.Taylor',  'Whale shark at 15m for 20 minutes. Once in a lifetime.',                5),
  ('2026-05-24 07:30:00', 5, 5, 50, 38.0, 27.5, 'Air',       220, 85, 'F.Cousteau','Barracuda tornado overhead. Three hammerheads on the deep wall.',        5);

-- Summary
SELECT 'Sites:'  AS '', COUNT(*) AS count FROM site
UNION ALL
SELECT 'Divers:', COUNT(*) FROM diver
UNION ALL
SELECT 'Dives:',  COUNT(*) FROM dive;

SQL

echo "Done. Open http://scuba-v3.10.38.48.141.nip.io to verify."
