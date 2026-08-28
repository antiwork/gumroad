#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/branch-specs' mapping layers: Public/Profile component
# fanout, a per-file config/ exception list, vitest co-location, lib/app
# content-attribution fallback, help_center view mapping, and the mailer
# template render graph. Also its behavior under an ASCII-only locale, where
# each read must name an encoding.
#
# Same shape as check_migration_versions_test.rb: throwaway git repos, no
# Rails. The selector runs from the repo root of the throwaway repo, so each
# scenario lays down the spec files its mapping should find.
#
#   ruby spec/bin/branch_specs_test.rb

require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

SELECTOR = File.expand_path("../../bin/branch-specs", __dir__)

$failures = []
$count = 0

def build_repo(dir, base_files:, head_files:, quote_path: nil)
  Dir.chdir(dir) do
    system("git init -q -b main .", exception: true)
    system("git config user.email t@t.t", exception: true)
    system("git config user.name t", exception: true)
    system("git config commit.gpgsign false", exception: true)
    system("git config core.quotePath #{quote_path}", exception: true) unless quote_path.nil?

    write = lambda do |files|
      files.each do |path, content|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content || "# noop\n")
      end
      system("git add -A", exception: true)
      system("git commit -q -m x --allow-empty", exception: true)
    end

    write.call(base_files)
    system("git branch -f base HEAD", exception: true)
    write.call(head_files)
  end
end

# Forces Encoding.default_external to US-ASCII, which the selector's reads have
# to survive. LC_ALL=C, not an empty LANG: capture3 merges into the current
# environment, an empty LC_ALL is ignored, and a stray LC_CTYPE restores UTF-8.
ASCII_LOCALE = { "LC_ALL" => "C", "LANG" => "C", "LC_CTYPE" => nil, "LANGUAGE" => nil }.freeze

# Captured output arrives tagged with this process's default_external, which is
# itself US-ASCII when the suite runs without a locale. Read it as UTF-8 so the
# non-ASCII expectations below compare as text rather than raising.
def utf8(str) = str.dup.force_encoding(Encoding::UTF_8)

def check(name, base_files:, head_files:, expect_specs: nil, expect_escalate: false, env: {}, quote_path: nil)
  $count += 1
  Dir.mktmpdir do |dir|
    build_repo(dir, base_files:, head_files:, quote_path:)
    stdout, stderr, status = Open3.capture3(env, "ruby", SELECTOR, "--base", "base", chdir: dir)
    stdout = utf8(stdout)
    stderr = utf8(stderr)

    if expect_escalate
      unless status.exitstatus == 3
        $failures << "#{name}: expected escalate (exit 3), got #{status.exitstatus}\nstdout: #{stdout}\nstderr: #{stderr}"
      end
    else
      unless status.success?
        $failures << "#{name}: expected success, got #{status.exitstatus}\nstderr: #{stderr}"
        return
      end
      got = stdout.split("\n").sort
      missing = (expect_specs || []) - got
      if missing.any?
        $failures << "#{name}: missing expected specs #{missing.inspect}\ngot: #{got.inspect}"
      end
    end
  end
end

SPEC_STUB = "# frozen_string_literal: true\n"

# Public lookup components + data layer -> PublicController coverage
check(
  "Public lookup component maps to public_controller + license lookup specs",
  base_files: {
    "spec/controllers/public_controller_spec.rb" => SPEC_STUB,
    "spec/requests/license_key_lookup_spec.rb" => SPEC_STUB,
    "app/javascript/components/Public/LookupLayout.tsx" => "old",
    "app/javascript/data/charge.ts" => "old",
  },
  head_files: {
    "app/javascript/components/Public/LookupLayout.tsx" => "new",
    "app/javascript/data/charge.ts" => "new",
  },
  expect_specs: %w[
    spec/controllers/public_controller_spec.rb
    spec/requests/license_key_lookup_spec.rb
  ],
)

# Profile component -> storefront request specs
check(
  "Profile component fans out to user/profile request specs",
  base_files: {
    "spec/requests/user/profile_spec.rb" => SPEC_STUB,
    "app/javascript/components/Profile/Layout.tsx" => "old",
  },
  head_files: { "app/javascript/components/Profile/Layout.tsx" => "new" },
  expect_specs: %w[spec/requests/user/profile_spec.rb],
)

# rack_attack initializer -> its dedicated request spec
check(
  "rack_attack initializer maps to rack_attack_spec instead of escalating",
  base_files: {
    "spec/requests/rack_attack_spec.rb" => SPEC_STUB,
    "config/initializers/rack_attack.rb" => "old",
  },
  head_files: { "config/initializers/rack_attack.rb" => "new" },
  expect_specs: %w[spec/requests/rack_attack_spec.rb],
)

# Other config files must still escalate — the map is per-file, not per-dir.
check(
  "unmapped config file still escalates",
  base_files: { "config/initializers/other.rb" => "old" },
  head_files: { "config/initializers/other.rb" => "new" },
  expect_escalate: true,
)

# Hung-checkout files are standalone ruby + a workflow that only invokes
# them, so they must not trip the mapping-gap escalate the way an unmapped
# helper would. Sibling model+spec so the run is not an empty selection.
check(
  "hung-checkout classifier, its test, and workflow do not escalate",
  base_files: {
    ".github/workflows/rerun-hung-checkout.yml" => "old",
    "bin/classify-hung-checkout" => "old",
    "spec/bin/classify_hung_checkout_test.rb" => "old",
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
  },
  head_files: {
    ".github/workflows/rerun-hung-checkout.yml" => "new",
    "bin/classify-hung-checkout" => "new",
    "spec/bin/classify_hung_checkout_test.rb" => "new",
    "app/models/widget.rb" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

# tests.yml is the suite itself and must still force the full suite.
check(
  "tests.yml still escalates",
  base_files: { ".github/workflows/tests.yml" => "old" },
  head_files: { ".github/workflows/tests.yml" => "new" },
  expect_escalate: true,
)

# Co-located vitest module is not a mapping gap
check(
  "TS module with co-located .test.ts does not escalate",
  base_files: {
    "app/javascript/utils/colombiaIdNumbers.ts" => "old",
    "app/javascript/utils/colombiaIdNumbers.test.ts" => "old",
    # something else in the diff must select a spec or the run is empty; the
    # escalate we're guarding against is the mapping-gap one.
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
  },
  head_files: {
    "app/javascript/utils/colombiaIdNumbers.ts" => "new",
    "app/javascript/utils/colombiaIdNumbers.test.ts" => "new",
    "app/models/widget.rb" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

# Evaporate context, types, and vendored client are vitest-only (lint_js).
check(
  "Evaporate context, types, and vendored client do not escalate",
  base_files: {
    "app/javascript/components/EvaporateUploader.tsx" => "old",
    "app/javascript/types/evaporate.d.ts" => "old",
    "vendor/assets/javascripts/evaporate.cjs" => "old",
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
  },
  head_files: {
    "app/javascript/components/EvaporateUploader.tsx" => "new",
    "app/javascript/types/evaporate.d.ts" => "new",
    "vendor/assets/javascripts/evaporate.cjs" => "new",
    "app/models/widget.rb" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

# lib file resolves via content attribution when name mapping misses
check(
  "lib file resolves via content attribution when name mapping misses",
  base_files: {
    "lib/utilities/compliance/colombia_id_number.rb" => "old",
    "spec/services/update_user_compliance_info_spec.rb" =>
      "#{SPEC_STUB}describe \"x\" do\n  it { ColombiaIdNumber.valid?(\"1\") }\nend\n",
  },
  head_files: { "lib/utilities/compliance/colombia_id_number.rb" => "new" },
  expect_specs: %w[spec/services/update_user_compliance_info_spec.rb],
)

# help_center article partial -> help_center request specs
check(
  "help_center article partial maps to help_center request specs",
  base_files: {
    "spec/requests/help_center_spec.rb" => SPEC_STUB,
    "app/views/help_center/articles/contents/_260-your-payout-settings-page.html.erb" => "old",
  },
  head_files: {
    "app/views/help_center/articles/contents/_260-your-payout-settings-page.html.erb" => "new",
  },
  expect_specs: %w[spec/requests/help_center_spec.rb],
)

MAILER_STUB = "# frozen_string_literal: true\n"

# The plain case: a mailer template is covered by its mailer's spec.
check(
  "mailer template maps to its mailer spec",
  base_files: {
    "app/mailers/contacting_creator_mailer.rb" => MAILER_STUB,
    "spec/mailers/contacting_creator_mailer_spec.rb" => SPEC_STUB,
    "app/views/contacting_creator_mailer/chargeback_evidence_due_soon.html.erb" => "old",
  },
  head_files: {
    "app/views/contacting_creator_mailer/chargeback_evidence_due_soon.html.erb" => "new",
  },
  expect_specs: %w[spec/mailers/contacting_creator_mailer_spec.rb],
)

# A partial another mailer renders must pull that mailer's spec in too.
check(
  "shared mailer partial pulls in the consuming mailer's spec",
  base_files: {
    "app/mailers/customer_mailer.rb" => MAILER_STUB,
    "app/mailers/customer_low_priority_mailer.rb" => MAILER_STUB,
    "spec/mailers/customer_mailer_spec.rb" => SPEC_STUB,
    "spec/mailers/customer_low_priority_mailer_spec.rb" => SPEC_STUB,
    "app/views/customer_mailer/_footer.html.erb" => "old",
    "app/views/customer_low_priority_mailer/notice.html.erb" =>
      %(<%= render("customer_mailer/footer") %>\n),
  },
  head_files: { "app/views/customer_mailer/_footer.html.erb" => "new" },
  expect_specs: %w[
    spec/mailers/customer_low_priority_mailer_spec.rb
    spec/mailers/customer_mailer_spec.rb
  ],
)

# The consumer is often one partial further out, so the walk is transitive:
# _item <- _items <- the other mailer's template.
check(
  "transitively shared mailer partial reaches the consuming mailer",
  base_files: {
    "app/mailers/customer_mailer.rb" => MAILER_STUB,
    "app/mailers/customer_low_priority_mailer.rb" => MAILER_STUB,
    "spec/mailers/customer_mailer_spec.rb" => SPEC_STUB,
    "spec/mailers/customer_low_priority_mailer_spec.rb" => SPEC_STUB,
    "app/views/customer_mailer/_item.html.erb" => "old",
    "app/views/customer_mailer/_items.html.erb" => %(<%= render("customer_mailer/item") %>\n),
    "app/views/customer_low_priority_mailer/notice.html.erb" =>
      %(<%= render("customer_mailer/items") %>\n),
  },
  head_files: { "app/views/customer_mailer/_item.html.erb" => "new" },
  expect_specs: %w[
    spec/mailers/customer_low_priority_mailer_spec.rb
    spec/mailers/customer_mailer_spec.rb
  ],
)

# A referrer outside app/views has no mailer spec to name, so the safe answer
# is the full suite — including when it is reached through another partial.
check(
  "mailer template a controller renders still escalates",
  base_files: {
    "app/mailers/customer_mailer.rb" => MAILER_STUB,
    "spec/mailers/customer_mailer_spec.rb" => SPEC_STUB,
    "app/views/customer_mailer/_receipt.html.erb" => "old",
    "app/controllers/api/internal/receipt_previews_controller.rb" =>
      %(render(template: "customer_mailer/receipt")\n),
  },
  head_files: { "app/views/customer_mailer/_receipt.html.erb" => "new" },
  expect_escalate: true,
)

check(
  "mailer partial transitively reaching a controller still escalates",
  base_files: {
    "app/mailers/customer_mailer.rb" => MAILER_STUB,
    "spec/mailers/customer_mailer_spec.rb" => SPEC_STUB,
    "app/views/customer_mailer/receipt/_item.html.erb" => "old",
    "app/views/customer_mailer/_receipt.html.erb" =>
      %(<%= render("customer_mailer/receipt/item") %>\n),
    "app/controllers/api/internal/receipt_previews_controller.rb" =>
      %(render(template: "customer_mailer/receipt")\n),
  },
  head_files: { "app/views/customer_mailer/receipt/_item.html.erb" => "new" },
  expect_escalate: true,
)

# Rails resolves a bare render against the mailer's prefix, so the walk has to
# follow those too or it stops before reaching the external consumer.
check(
  "bare render keeps the walk going to the consuming mailer",
  base_files: {
    "app/mailers/affiliate_mailer.rb" => MAILER_STUB,
    "app/mailers/affiliate_request_mailer.rb" => MAILER_STUB,
    "spec/mailers/affiliate_mailer_spec.rb" => SPEC_STUB,
    "spec/mailers/affiliate_request_mailer_spec.rb" => SPEC_STUB,
    "app/views/affiliate_mailer/_footer.html.erb" => "old",
    # renders the partial by bare name, and is itself rendered by the other mailer
    "app/views/affiliate_mailer/invitation.html.erb" => %(<%= render("footer") %>\n),
    "app/views/affiliate_request_mailer/approved.html.erb" =>
      %(<%= render("affiliate_mailer/invitation") %>\n),
  },
  head_files: { "app/views/affiliate_mailer/_footer.html.erb" => "new" },
  expect_specs: %w[
    spec/mailers/affiliate_mailer_spec.rb
    spec/mailers/affiliate_request_mailer_spec.rb
  ],
)

# The owner having a spec must not paper over a consumer that has none.
check(
  "consuming mailer without a spec escalates even when the owner has one",
  base_files: {
    "app/mailers/customer_mailer.rb" => MAILER_STUB,
    "app/mailers/support_contact_mailer.rb" => MAILER_STUB,
    "spec/mailers/customer_mailer_spec.rb" => SPEC_STUB,
    "app/views/customer_mailer/_footer.html.erb" => "old",
    "app/views/support_contact_mailer/notice.html.erb" =>
      %(<%= render("customer_mailer/footer") %>\n),
  },
  head_files: { "app/views/customer_mailer/_footer.html.erb" => "new" },
  expect_escalate: true,
)

# No spec/mailers/<mailer>_spec.rb means nothing to select; do not invent one.
check(
  "mailer template with no mailer spec still escalates",
  base_files: {
    "app/mailers/support_contact_mailer.rb" => MAILER_STUB,
    "app/views/support_contact_mailer/contact_form.html.erb" => "old",
  },
  head_files: { "app/views/support_contact_mailer/contact_form.html.erb" => "new" },
  expect_escalate: true,
)

# An unrelated spec named after the mailer must not stand in for the render
# graph and keep the selector from escalating.
check(
  "unsafe mailer graph escalates even when a view spec exists for the directory",
  base_files: {
    "app/mailers/customer_mailer.rb" => MAILER_STUB,
    "spec/mailers/customer_mailer_spec.rb" => SPEC_STUB,
    "spec/views/customer_mailer/receipt_spec.rb" => SPEC_STUB,
    "app/views/customer_mailer/_receipt.html.erb" => "old",
    "app/controllers/api/internal/receipt_previews_controller.rb" =>
      %(render(template: "customer_mailer/receipt")\n),
  },
  head_files: { "app/views/customer_mailer/_receipt.html.erb" => "new" },
  expect_escalate: true,
)

# Bare renders resolve through inherited prefixes, so a parent mailer's
# templates are reachable from view trees the walk never visits.
check(
  "template of a mailer other mailers inherit from escalates",
  base_files: {
    "app/mailers/application_mailer.rb" => "class ApplicationMailer < ActionMailer::Base\nend\n",
    "app/mailers/customer_mailer.rb" => "class CustomerMailer < ApplicationMailer\nend\n",
    "spec/mailers/application_mailer_spec.rb" => SPEC_STUB,
    "spec/mailers/customer_mailer_spec.rb" => SPEC_STUB,
    "app/views/application_mailer/_footer.html.erb" => "old",
    "app/views/customer_mailer/notice.html.erb" => %(<%= render("footer") %>\n),
  },
  head_files: { "app/views/application_mailer/_footer.html.erb" => "new" },
  expect_escalate: true,
)

# A non-mailer view directory must not pick up a mailer spec.
check(
  "non-mailer view directory does not map to spec/mailers",
  base_files: {
    "spec/mailers/products_spec.rb" => SPEC_STUB,
    "app/views/products/show.html.erb" => "old",
  },
  head_files: { "app/views/products/show.html.erb" => "new" },
  expect_escalate: true,
)

# A genuinely unmapped app file must still escalate (the guard this whole
# selector exists for).
check(
  "unmapped app file still escalates",
  base_files: { "app/javascript/components/Novel/Thing.tsx" => "old" },
  head_files: { "app/javascript/components/Novel/Thing.tsx" => "new" },
  expect_escalate: true,
)

# --- Locale handling -------------------------------------------------------
#
# Three reads can carry non-ASCII bytes: the header comments via --help, git
# paths, and grep paths. Under an ASCII-only locale an unqualified read of any
# of them raises ArgumentError.

# --help takes no base ref, so it does not fit check().
def check_help_under_ascii_locale
  $count += 1
  stdout, stderr, status = Open3.capture3(ASCII_LOCALE, "ruby", SELECTOR, "--help")
  stdout = utf8(stdout)
  stderr = utf8(stderr)
  name = "--help renders under an ASCII-only locale"
  if !status.success?
    $failures << "#{name}: exit #{status.exitstatus}\nstderr: #{stderr}"
  elsif !stdout.include?("Usage:")
    $failures << "#{name}: header block missing from output\nstdout: #{stdout}"
  elsif !stdout.include?("—")
    $failures << "#{name}: em-dash lost, so the read transcoded\nstdout: #{stdout}"
  end
end
check_help_under_ascii_locale

# git prints raw path bytes when core.quotePath is off.
check(
  "non-ASCII changed path maps under an ASCII-only locale",
  base_files: {
    "app/models/café.rb" => "old",
    "spec/models/café_spec.rb" => SPEC_STUB,
  },
  head_files: { "app/models/café.rb" => "new" },
  expect_specs: ["spec/models/café_spec.rb"],
  env: ASCII_LOCALE,
  quote_path: false,
)

# grep prints raw path bytes always, so content attribution needs the same care.
check(
  "non-ASCII spec filename resolves by content under an ASCII-only locale",
  base_files: {
    "lib/utilities/compliance/colombia_id_number.rb" => "old",
    "spec/services/café_compliance_spec.rb" =>
      "#{SPEC_STUB}describe \"x\" do\n  it { ColombiaIdNumber.valid?(\"1\") }\nend\n",
  },
  head_files: { "lib/utilities/compliance/colombia_id_number.rb" => "new" },
  expect_specs: ["spec/services/café_compliance_spec.rb"],
  env: ASCII_LOCALE,
  quote_path: false,
)

# Bytes that are no valid encoding must be refused, not scrubbed: U+FFFD can
# name a different real file. They come from a stub grep because APFS rejects
# such filenames, so a real-file fixture would only ever run on Linux. The
# assertion is on stderr because scrubbing also exits 3, via a mapping gap.
def check_invalid_path_bytes_rejected(name, base_files:, head_files:)
  $count += 1
  Dir.mktmpdir do |dir|
    build_repo(dir, base_files:, head_files:)
    stub = File.join(dir, "stub-bin")
    FileUtils.mkdir_p(stub)
    File.write(File.join(stub, "grep"), "#!/bin/sh\nprintf 'spec/bad\\377_spec.rb\\n'\n")
    FileUtils.chmod(0o755, File.join(stub, "grep"))

    env = ASCII_LOCALE.merge("PATH" => "#{stub}:#{ENV.fetch('PATH')}")
    _stdout, stderr, status = Open3.capture3(env, "ruby", SELECTOR, "--base", "base", chdir: dir)
    stderr = utf8(stderr).scrub

    if status.exitstatus != 3
      $failures << "#{name}: expected escalate (exit 3), got #{status.exitstatus}\nstderr: #{stderr}"
    elsif !stderr.include?("not valid UTF-8")
      $failures << "#{name}: escalated for the wrong reason, so the bytes were reinterpreted\nstderr: #{stderr}"
    end
  end
end
# Both greps that read path names: content attribution, and the mailer render
# graph. Each reaches its grep first for the diff it is given.
check_invalid_path_bytes_rejected(
  "invalid path bytes from the content-attribution grep are refused",
  base_files: { "lib/utilities/compliance/colombia_id_number.rb" => "old" },
  head_files: { "lib/utilities/compliance/colombia_id_number.rb" => "new" },
)

check_invalid_path_bytes_rejected(
  "invalid path bytes from the mailer render-graph grep are refused",
  base_files: {
    "app/mailers/customer_mailer.rb" => MAILER_STUB,
    "spec/mailers/customer_mailer_spec.rb" => SPEC_STUB,
    "app/views/customer_mailer/_footer.html.erb" => "old",
  },
  head_files: { "app/views/customer_mailer/_footer.html.erb" => "new" },
)

# VCR tapes are recordings, not helpers. Pairing one with a mapped spec
# must not force the full suite (the escalate that put refund-only PRs
# onto 50 Slow checkout shards).
check(
  "VCR cassette with a mapped spec does not escalate",
  base_files: {
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
    "spec/support/fixtures/vcr_cassettes/Widget/example.yml" => "old",
  },
  head_files: {
    "app/models/widget.rb" => "new",
    "spec/models/widget_spec.rb" => "#{SPEC_STUB}# changed\n",
    "spec/support/fixtures/vcr_cassettes/Widget/example.yml" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

# A tape-only change has no mapped spec left after ignore. Escalate so a
# re-recorded or malformed cassette cannot merge with an empty Relevant run.
check(
  "VCR cassette-only diff escalates",
  base_files: {
    "spec/support/fixtures/vcr_cassettes/Widget/example.yml" => "old",
  },
  head_files: {
    "spec/support/fixtures/vcr_cassettes/Widget/example.yml" => "new",
  },
  expect_escalate: true,
)

# Real helper changes under spec/support still need the full suite.
check(
  "unmapped spec/support helper still escalates",
  base_files: { "spec/support/mystery_helpers.rb" => "old" },
  head_files: { "spec/support/mystery_helpers.rb" => "new" },
  expect_escalate: true,
)


# Recurring run-all-specs gaps: ProductEdit JS has no per-file rspec.
check(
  "ProductEdit component fans out to product request specs",
  base_files: {
    "spec/requests/products/edit/covers_spec.rb" => SPEC_STUB,
    "app/javascript/components/ProductEdit/state.ts" => "old",
  },
  head_files: { "app/javascript/components/ProductEdit/state.ts" => "new" },
  expect_specs: %w[spec/requests/products/edit/covers_spec.rb],
)

check(
  "Settings page fans out to settings request specs",
  base_files: {
    "spec/requests/settings/main_spec.rb" => SPEC_STUB,
    "app/javascript/pages/Settings/Main.tsx" => "old",
  },
  head_files: { "app/javascript/pages/Settings/Main.tsx" => "new" },
  expect_specs: %w[spec/requests/settings/main_spec.rb],
)

check(
  "dynamodb support file maps instead of escalating",
  base_files: {
    "spec/services/email_engagement_dynamo_store_spec.rb" => SPEC_STUB,
    "spec/support/dynamodb.rb" => "old",
  },
  head_files: { "spec/support/dynamodb.rb" => "new" },
  expect_specs: %w[spec/services/email_engagement_dynamo_store_spec.rb],
)

check(
  "public image with a mapped spec does not escalate",
  base_files: {
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
    "public/images/help_center/foo.png" => "old",
  },
  head_files: {
    "app/models/widget.rb" => "new",
    "public/images/help_center/foo.png" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

check(
  "non-tests workflow with a mapped spec does not escalate",
  base_files: {
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
    ".github/workflows/e2e.yml" => "old",
  },
  head_files: {
    "app/models/widget.rb" => "new",
    ".github/workflows/e2e.yml" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

check(
  "reuse-full-suite script with a mapped spec does not escalate",
  base_files: {
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
    "bin/reuse-full-suite" => "old",
  },
  head_files: {
    "app/models/widget.rb" => "new",
    "bin/reuse-full-suite" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

check(
  "reuse-full-suite-only change does not escalate",
  base_files: {
    "bin/reuse-full-suite" => "old",
    "script/test-reuse-full-suite" => "old",
  },
  head_files: {
    "bin/reuse-full-suite" => "new",
    "script/test-reuse-full-suite" => "new",
  },
  expect_specs: [],
)

WORKFLOW = File.expand_path("../../.github/workflows/tests.yml", __dir__)
workflow = YAML.load_file(WORKFLOW)
migration_versions = workflow.fetch("jobs").fetch("migration_versions")
reuse_self_test = migration_versions.fetch("steps").find do |step|
  step["name"] == "Self-test reuse-full-suite"
end
$count += 1
unless reuse_self_test && reuse_self_test["run"] == "bash script/test-reuse-full-suite" && !reuse_self_test.key?("if")
  $failures << "tests.yml does not run script/test-reuse-full-suite as an ungated migration_versions step"
end

if $failures.empty?

  puts "#{$count} checks passed"
else
  $failures.each { |f| puts "FAIL: #{f}\n\n" }
  abort "#{$failures.size}/#{$count} checks failed"
end
