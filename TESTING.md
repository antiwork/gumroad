# Testing toggles and focused runs

This repository has a few environment toggles to improve local/system spec stability and to validate the product editor save shortcut.

Toggles
- REACT_ON_RAILS_PRERENDER
  - Default in test: disabled for most components to avoid unrelated SSR bundle errors.
  - Set to true to re-enable SSR for all components.
  - Note: In test, SSR is allowlisted for ProductEditPage even when false, so we still cover SSR there.
- DISABLE_ACCOUNT_SWITCH_UI
  - When true, system specs bypass fragile UI account switching and log in as the seller directly.
- PRODUCT_EDITOR_SAVE_SHORTCUT
  - Build-time flag (via webpack DefinePlugin) controlling Cmd/Ctrl+S save shortcut in Product Editor. Set to false to disable keyboard shortcut and aria-keyshortcuts.

Focused spec examples (from PR discussion)
- spec/requests/products/edit/rich_text_editor_spec.rb:289
- spec/requests/products/edit/edit_spec.rb:591

Example commands
- Baseline (bypass nav fragility):
  DISABLE_ACCOUNT_SWITCH_UI=true RAILS_ENV=test bundle exec rspec \
    spec/requests/products/edit/edit_spec.rb:591 \
    spec/requests/products/edit/rich_text_editor_spec.rb:289 \
    --format documentation --force-color --no-profile

- SSR on (for coverage):
  REACT_ON_RAILS_PRERENDER=true DISABLE_ACCOUNT_SWITCH_UI=true RAILS_ENV=test bundle exec rspec \
    spec/requests/products/edit/edit_spec.rb:591 \
    spec/requests/products/edit/rich_text_editor_spec.rb:289 \
    --format documentation --force-color --no-profile

- Flag off (disable save shortcut + aria-keyshortcuts):
  PRODUCT_EDITOR_SAVE_SHORTCUT=false DISABLE_ACCOUNT_SWITCH_UI=true RAILS_ENV=test bundle exec rspec \
    spec/requests/products/edit/save_shortcut_spec.rb \
    --format documentation --force-color --no-profile

- SSR on + Flag off:
  REACT_ON_RAILS_PRERENDER=true PRODUCT_EDITOR_SAVE_SHORTCUT=false DISABLE_ACCOUNT_SWITCH_UI=true RAILS_ENV=test bundle exec rspec \
    spec/requests/products/edit/save_shortcut_spec.rb \
    --format documentation --force-color --no-profile

Notes
- JS builds respect PRODUCT_EDITOR_SAVE_SHORTCUT at build time. If changing it locally for tests, trigger a Webpack build if needed. RSpec will build test packs via shakapacker when required.
- Screenshots and HTML artifacts are saved alongside failing examples by default (see spec_helper.rb). We additionally keep a .screenshots folder for curated UI captures.

