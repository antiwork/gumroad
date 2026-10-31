#!/bin/bash
export GUMROAD_REPO=~/code/gumroad
P=~/.hermes/skills/gumroad/gumroad-prod-console-pointer/scripts/prod_sql.sh
cd ~/.hermes/cache/scratch/ffs
for n in stripe paypal; do
  bash $P "weekly fingerprint scan $n" "financial-fingerprint-scan" "$(cat $n.sql)" > $n.json 2> $n.err
  echo "$n rc=$?"
done
