#!/usr/bin/env bash
# Reproduce the Synthea cohort used in this project (Java 17+ required).
# Two seeded batches of Massachusetts adults aged 30-85, full history, four CSVs only.
# The shipped data = batch 1 (seed 2026, stopped after 4,690 patients) + batch 2 (seed 9999, 11,124 patients incl. deceased).
set -euo pipefail
curl -sSL -o synthea.jar https://github.com/synthetichealth/synthea/releases/download/master-branch-latest/synthea-with-dependencies.jar

COMMON="--exporter.csv.export=true --exporter.fhir.export=false --exporter.hospital.fhir.export=false \
 --exporter.practitioner.fhir.export=false --exporter.metadata.export=false --exporter.years_of_history=0 \
 --exporter.csv.included_files=patients.csv,conditions.csv,medications.csv,encounters.csv"

java -Xmx4g -jar synthea.jar -s 2026 -cs 2026 -p 4700 -a 30-85 $COMMON --exporter.baseDirectory=./batch1/ Massachusetts
java -Xmx4g -jar synthea.jar -s 9999 -cs 9999 -p 9000 -a 30-85 $COMMON --exporter.baseDirectory=./batch2/ Massachusetts

# merge the two batches (keep one header per file)
mkdir -p synthea_csv
for f in patients conditions medications encounters; do
  head -1 batch1/csv/$f.csv > synthea_csv/$f.csv
  tail -n +2 batch1/csv/$f.csv >> synthea_csv/$f.csv
  tail -n +2 batch2/csv/$f.csv >> synthea_csv/$f.csv
done
ls -la synthea_csv
# Note: Synthea's master build changes over time, so a regenerated cohort will differ
# slightly from the one reported in docs/. Use the shipped CSVs for identical numbers.
