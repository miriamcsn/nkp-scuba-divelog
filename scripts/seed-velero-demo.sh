#!/usr/bin/env bash
# Seed the scuba MySQL database with velero demo data:
#   5 dive sites, 5 divers, 7 dives
#
# Usage:
#   export KUBECONFIG=~/.kube/manager/nkp-wlc-a-kubeconfig.conf
#   ./scripts/seed-velero-demo.sh

set -e

NAMESPACE="${NAMESPACE:-miriam-scuba-demo}"
POD="${POD:-scuba-mysql-0}"
DB="${DB:-scubadb}"
ROOT_PW="${ROOT_PW:-48db5bd8681bfaf23e25a002aa3f7e12}"

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
  ('Devil''s Crown',    'Floreana Island', 'Ecuador',    30,  '25m',  'strong',   'Galápagos penguins, sea lions, white-tip reef sharks, eagle rays', 'strong surge inside the crater, sea lion jealousy'),
  ('USAT Liberty Wreck','Tulamben',        'Indonesia',  30,  '20m',  'mild',     'bumphead parrotfish, pygmy seahorses, nudibranch bonanza',         'night dive recommended, occasional volcanic sand shift'),
  ('The Cathedral',     'Pico Island',     'Portugal',   25,  '30m',  'minimal',  'sperm whales nearby, rays, amberjacks, moray eels',                'Atlantic swell, cold at depth'),
  ('Gran Cenote',       'Tulum',           'Mexico',     12,  '60m',  'none',     'freshwater turtles, cave shrimp, blind fish',                      'halocline disorientation, narrow passages'),
  ('Beqa Lagoon',       'Pacific Harbour', 'Fiji',       30,  '20m',  'mild',     '8+ bull sharks, nurse sharks, white-tips, Napoleon wrasse',        'bull sharks fed by guides, respect the protocol');

-- 5 divers
INSERT INTO diver
  (name, age, city, school, cert_id, cert_level)
VALUES
  ('Nemo Falcão',    34, 'Florianópolis', 'PADI Brazil',     'PADI-BR-4421', 'Tec 45'),
  ('Asha Patel',     29, 'Mumbai',        'SSI India',       'SSI-IN-0882',  'Divemaster'),
  ('Riku Tanaka',    41, 'Yokohama',      'PADI Japan',      'PADI-JP-3309', 'Master Scuba Diver'),
  ('Ingrid Bjornsen',38, 'Bergen',        'PADI Norway',     'PADI-NO-1157', 'Divemaster'),
  ('Diego Reyes',    27, 'Tulum',         'NAUI Mexico',     'NAUI-MX-5544', 'Advanced Open Water');

-- 7 dives
INSERT INTO dive
  (date, diver_id, site_id, duration_min, max_depth_m, water_temp_c, gas_mix, tank_pressure_start_bar, tank_pressure_end_bar, buddy, notes, rating)
VALUES
  ('2026-06-01 07:15:00', 1, 1, 52, 38.0, 20.0, 'Nitrox32', 220, 55, 'D.Reyes',
   'Briefing said max 30m. I went to 38. The eagle rays were at 38. No regrets. Sea lion stole Diegos fin at 15m. He was not happy.',
   5),

  ('2026-06-02 09:00:00', 2, 2, 65, 26.0, 29.0, 'Air',      215, 70, 'R.Tanaka',
   'Riku wanted to photograph artifacts. I found a Mexichromis trilineata nudibranch on the port engine. We were there 45 minutes. The WWII history was also fine.',
   5),

  ('2026-06-02 14:30:00', 3, 2, 58, 28.5, 29.0, 'Air',      220, 80, 'A.Patel',
   'Documented: 1x bow gun intact, 2x cargo hold entry points, 1x porthole serial number photographed. Asha spent 20 minutes on a 2cm nudibranch. Efficient use of time.',
   4),

  ('2026-06-03 08:00:00', 4, 5, 45, 28.0, 29.5, 'Air',      210, 90, 'N.Falcao',
   '29 degrees again. I am melting. Norway has proper cold — 8 degrees, full drysuit, you know you are alive. Eight bull sharks. That part was acceptable. Nemo tried to touch one.',
   4),

  ('2026-06-04 10:30:00', 5, 4, 48, 11.0, 24.0, 'Air',      200, 85, 'Solo guide',
   'First cenote dive. Did not expect the halocline to look like the viz had gone to zero. Panicked briefly. Guide pointed up. Remembered I was fine. The turtles inside are completely unbothered by humans. I want to be a turtle.',
   5),

  ('2026-06-05 07:00:00', 1, 5, 55, 30.0, 29.0, 'Nitrox32', 220, 60, 'I.Bjornsen',
   '8 bull sharks on the sand. Asked the guide for 10 more minutes. Guide said no. Asked again. Guide said no again. Ingrid was watching a nurse shark sleep. A peaceful dive. Except for my negotiation attempts.',
   5),

  ('2026-06-06 11:00:00', 2, 3, 44, 22.0, 17.0, 'Air',      215, 95, 'R.Tanaka',
   'The Cathedral light columns at 10m were genuinely beautiful. Found a Flabellina nudibranch at 18m — rare for Atlantic. Riku photographed the structural geology. We are different people. Both happy.',
   5);

-- Summary
SELECT 'Sites:'  AS '', COUNT(*) AS count FROM site
UNION ALL
SELECT 'Divers:', COUNT(*) FROM diver
UNION ALL
SELECT 'Dives:',  COUNT(*) FROM dive;

SQL

echo "Done. Data seeded into ${DB}."
