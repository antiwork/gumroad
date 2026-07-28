#!/bin/bash
set -euo pipefail

export TERM=xterm-256color GIT_PAGER=cat PAGER=cat
cd "$(git rev-parse --show-toplevel)"
base_ref="${1:-origin/main}"

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
git --no-pager show "$base_ref":app/models/rich_content.rb | sed -n '/def embedded_files_belong_to_product/,/^    end$/p'
sleep 2

printf "%b\n" ""
printf "%b\n" "=== The change ==="
git --no-pager diff --stat "$base_ref"...HEAD
sleep 1
printf "%b\n" ""
git --no-pager diff "$base_ref"...HEAD -- app/models/rich_content.rb
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Reproducing the seller's dead end, then the narrow fix, on persisted records ==="
printf "%b\n" "(product A owns a file, B embeds it, the file is soft-deleted -> B is unsaveable)"
sleep 1
bundle exec rspec spec/models/rich_content_spec.rb \
  -e "when the foreign file has been soft-deleted" \
  --format documentation --no-profile 2>&1 \
  | grep -vE "Elasticsearch|^warning|DEPRECATION|sidekiq-pro|^\[ES\]|Sidekiq 7|Run options|mysql_missing_table|makara|db/schema|boot\.rb|webmock|constant Net::HTTPSession|Tasks: TOP|full trace|bin/rails aborted|StatementInvalid|Mysql2::Error|Caused by:|^$"
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Product editor reconciles the cleanup and saves twice without a reload ==="
test_line="$(grep -n 'PUT update reconciles a stale dead cross-product file embed before the next save' test/controllers/links_controller_test.rb | cut -d: -f1)"
bundle exec rails test "test/controllers/links_controller_test.rb:$test_line" 2>&1 \
  | grep -vE "Elasticsearch|^warning|DEPRECATION|sidekiq-pro|^\[ES\]|Sidekiq 7|Run options|mysql_missing_table|makara|db/schema|boot\.rb|webmock|constant Net::HTTPSession|Tasks: TOP|full trace|bin/rails aborted|StatementInvalid|Mysql2::Error|Caused by:|^$"
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Tabs opened before provenance shipped still move and copy safely ==="
printf "%b\n" "Marker-less moves are inferred only when one submitted reference to a stored"
printf "%b\n" "page changes owner scope. A repeated page ID cannot fit the response's global ID"
printf "%b\n" "mapping, so the server rejects it before mutation and tells the seller to reload."
printf "%b\n" "Marker-less copies can remove only dead IDs proven to exist in this product's stored pages."
printf "%b\n" "A provenance-aware request without that proof still fails ownership validation."
bundle exec rails test test/controllers/links_controller_test.rb \
  -n '/(infers a stale-embed move from an already-open editor tab|repairs a stale embed when copying a page between versions|repairs a stale embed copied by an already-open editor tab|does not apply old-tab copy fallback|does not accept stale-embed provenance from another product|moving a shared page to a version|moving a version page to shared content|page ID kept in its source and destination)/' 2>&1 \
  | grep -vE "Elasticsearch|^warning|DEPRECATION|sidekiq-pro|^\[ES\]|Sidekiq 7|Run options|mysql_missing_table|makara|db/schema|boot\.rb|webmock|constant Net::HTTPSession|Tasks: TOP|full trace|bin/rails aborted|StatementInvalid|Mysql2::Error|Caused by:|^$"
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Browser state removes the reported node and preserves every other edit ==="
npx vitest run app/javascript/data/product_edit.test.ts 2>&1 \
  | grep -vE "^$|^ RUN |^   Start at|^   Duration"
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Variant API round trip also removes the stale file link ==="
bundle exec rspec spec/controllers/api/v2/variants_controller_spec.rb \
  -e "removes a soft-deleted foreign embed and its stale variant file link" \
  --format documentation --no-profile 2>&1 \
  | grep -vE "Elasticsearch|^warning|DEPRECATION|sidekiq-pro|^\[ES\]|Sidekiq 7|Run options|mysql_missing_table|makara|db/schema|boot\.rb|webmock|constant Net::HTTPSession|Tasks: TOP|full trace|bin/rails aborted|StatementInvalid|Mysql2::Error|Caused by:|^$"
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Trusted stored-content copies prune stale embeds and empty groups explicitly ==="
bundle exec rspec spec/controllers/api/v2/links_controller_spec.rb \
  -e "drops a stale dead foreign embed when copying" \
  spec/services/product_duplicator_service_spec.rb \
  -e "prunes a file embed group whose only child is a stale dead foreign embed" \
  --format documentation --no-profile 2>&1 \
  | grep -vE "Elasticsearch|^warning|DEPRECATION|sidekiq-pro|^\[ES\]|Sidekiq 7|Run options|mysql_missing_table|makara|db/schema|boot\.rb|webmock|constant Net::HTTPSession|Tasks: TOP|full trace|bin/rails aborted|StatementInvalid|Mysql2::Error|Caused by:|^$"
sleep 2

printf "%b\n" ""
printf "%b\n" "=== Full group, including the cases that must STILL be rejected ==="
bundle exec rspec spec/models/rich_content_spec.rb \
  -e "rejecting cross-product file embeds" \
  --format documentation --no-profile 2>&1 \
  | grep -vE "Elasticsearch|^warning|DEPRECATION|sidekiq-pro|^\[ES\]|Sidekiq 7|Run options|mysql_missing_table|makara|db/schema|boot\.rb|webmock|constant Net::HTTPSession|Tasks: TOP|full trace|bin/rails aborted|StatementInvalid|Mysql2::Error|Caused by:|^$"
sleep 3
