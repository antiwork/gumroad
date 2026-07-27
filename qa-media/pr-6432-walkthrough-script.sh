#!/bin/bash
export TERM=xterm-256color GIT_PAGER=cat PAGER=cat
cd /tmp/gr-1413-embeds

printf "%b\n" "=== gp#1413 — a pre-#5416 cross-product fileEmbed permanently blocks every save ==="
sleep 1
printf "%b\n" ""
printf "%b\n" "The validation added in #5416 (app/models/rich_content.rb) is retroactive:"
printf "%b\n" "rows written BEFORE it merged can already carry a foreign embed, so it fires"
printf "%b\n" "on every save of an untouched page. When the foreign file is soft-deleted the"
printf "%b\n" "embed renders as nothing, so the seller has no node to remove and no way out."
sleep 2
printf "%b\n" ""
printf "%b\n" "--- The validation as it stands on main ---"
git --no-pager show origin/main:app/models/rich_content.rb | sed -n '255,270p'
sleep 2

printf "%b\n" ""
printf "%b\n" "=== The change ==="
git --no-pager diff --stat
sleep 1
printf "%b\n" ""
git --no-pager diff -- app/models/rich_content.rb
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Reproducing the seller's dead end, then the fix, on real records ==="
printf "%b\n" "(product A owns a file, B embeds it, the file is soft-deleted -> B is unsaveable)"
sleep 1
bundle exec rspec spec/models/rich_content_spec.rb \
  -e "when the foreign file has been soft-deleted" \
  --format documentation --no-profile 2>&1 \
  | grep -vE "Elasticsearch|^warning|DEPRECATION|sidekiq-pro|^\[ES\]|Sidekiq 7|Run options|mysql_missing_table|makara|db/schema|boot\.rb|Tasks: TOP|full trace|bin/rails aborted|StatementInvalid|Mysql2::Error|Caused by:|^$"
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Full group, including the cases that must STILL be rejected ==="
bundle exec rspec spec/models/rich_content_spec.rb \
  -e "rejecting cross-product file embeds" \
  --format documentation --no-profile 2>&1 \
  | grep -vE "Elasticsearch|^warning|DEPRECATION|sidekiq-pro|^\[ES\]|Sidekiq 7|Run options|mysql_missing_table|makara|db/schema|boot\.rb|Tasks: TOP|full trace|bin/rails aborted|StatementInvalid|Mysql2::Error|Caused by:|^$"
sleep 3
