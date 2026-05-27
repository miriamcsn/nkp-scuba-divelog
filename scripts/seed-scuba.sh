#!/usr/bin/env bash
# Seed the scuba MySQL database with demo data:
#   3 dive sites, 3 divers, 4 dives
#
# Usage:
#   export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
#   ./seed-scuba.sh
#
# Schema matches the actual scuba-divelog tables (site, diver, dive — singular).

set -e

NAMESPACE="${NAMESPACE:-miriam-scuba}"
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

-- 3 dive sites
INSERT INTO site
  (name, city, country, typical_max_depth_m, typical_visibility, current_strength, marine_life, hazards)
VALUES
  ('Blue Hole',      'Dahab',         'Egypt',     100, '30m',  'mild',     'reef fish, fusiliers, occasional reef shark', 'deep arch, narcosis risk'),
  ('SS Yongala',     'Townsville',    'Australia',  30, '15m',  'strong',   'bull sharks, sea snakes, giant grouper',      'strong current, deep wreck'),
  ('Silfra Fissure', 'Thingvellir',   'Iceland',    18, '100m', 'minimal',  'sparse — clarity is the attraction',          'cold water (2C), drysuit required');

-- 3 divers
INSERT INTO diver
  (name, age, city, school, cert_id, cert_level)
VALUES
  ('Miriam Gorino',    32, 'Sao Paulo',  'PADI Brazil',  'PADI-998877', 'Rescue Diver'),
  ('Jacques Cousteau', 56, 'Saint-Andre','PADI France',  'PADI-000001', 'Master Scuba Diver'),
  ('Sylvia Earle',     45, 'Gibbstown',  'PADI USA',     'PADI-123456', 'Divemaster');

-- 4 dives (site_id and diver_id reference the rows we just inserted)
INSERT INTO dive
  (date, diver_id, site_id, duration_min, max_depth_m, water_temp_c, gas_mix, tank_pressure_start_bar, tank_pressure_end_bar, buddy, notes, rating)
VALUES
  ('2026-05-20 09:30:00', 1, 1, 38, 42.5, 24.0, 'Air',      210, 60, 'Cousteau',   'Reached the arch. Visibility ~30m. Fusiliers everywhere.', 5),
  ('2026-05-21 11:00:00', 2, 2, 45, 28.0, 22.5, 'Nitrox32', 220, 80, 'Earle',      'Bull sharks circling the bow. Strong current — held the line.', 5),
  ('2026-05-22 13:15:00', 1, 3, 60, 12.0,  2.0, 'Air',      230, 90, 'Solo',       'Crystal clear glacial water. Drysuit dive. Surreal.',     4),
  ('2026-05-23 10:00:00', 3, 1, 50, 18.0, 24.5, 'Air',      215, 70, 'Student-A',  'Easy training dive. Calm conditions.',                    4);

-- Summary
SELECT 'Sites:'  AS '', COUNT(*) AS count FROM site
UNION ALL
SELECT 'Divers:', COUNT(*) FROM diver
UNION ALL
SELECT 'Dives:',  COUNT(*) FROM dive;

SQL

echo "Done. Open the scuba UI to verify."
