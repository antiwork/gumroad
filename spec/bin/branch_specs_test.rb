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

def build_repo(dir, base_files:, head_files:, head_deletes: [], quote_path: nil)
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
    FileUtils.rm(head_deletes)
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

def check(name, base_files:, head_files:, head_deletes: [], expect_specs: nil, reject_specs: [], expect_escalate: false, expect_reason: nil, env: {}, quote_path: nil)
  $count += 1
  Dir.mktmpdir do |dir|
    build_repo(dir, base_files:, head_files:, head_deletes:, quote_path:)
    stdout, stderr, status = Open3.capture3(env, "ruby", SELECTOR, "--base", "base", chdir: dir)
    stdout = utf8(stdout)
    stderr = utf8(stderr)

    if expect_escalate
      unless status.exitstatus == 3
        $failures << "#{name}: expected escalate (exit 3), got #{status.exitstatus}\nstdout: #{stdout}\nstderr: #{stderr}"
      end
      if expect_reason && !stderr.include?(expect_reason)
        $failures << "#{name}: expected escalate reason #{expect_reason.inspect}\nstderr: #{stderr}"
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
      leaked = reject_specs & got
      $failures << "#{name}: selected specs it must not select #{leaked.inspect}" if leaked.any?
      # A non-empty list is a floor; an empty one means the selector prints nothing.
      if expect_specs == [] && got.any?
        $failures << "#{name}: expected no specs\ngot: #{got.inspect}"
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

# Nested oauth/device_authorizations controller -> flattened request spec name
check(
  "nested oauth controller maps to flattened request spec",
  base_files: {
    "spec/requests/oauth_device_authorizations_spec.rb" => SPEC_STUB,
    "app/controllers/oauth/device_authorizations_controller.rb" => "old",
  },
  head_files: { "app/controllers/oauth/device_authorizations_controller.rb" => "new" },
  expect_specs: %w[spec/requests/oauth_device_authorizations_spec.rb],
)

check(
  "nested oauth device authorization view maps to flattened request spec",
  base_files: {
    "spec/requests/oauth_device_authorizations_spec.rb" => SPEC_STUB,
    "app/views/oauth/device_authorizations/new.html.erb" => "old",
  },
  head_files: { "app/views/oauth/device_authorizations/new.html.erb" => "new" },
  expect_specs: %w[spec/requests/oauth_device_authorizations_spec.rb],
)

check(
  "doorkeeper authorize view maps to oauth authorize request specs",
  base_files: {
    "spec/requests/oauth_authorizations_spec.rb" => SPEC_STUB,
    "spec/requests/oauth_authorize_scope_list_spec.rb" => SPEC_STUB,
    "app/views/doorkeeper/authorizations/new.html.erb" => "old",
  },
  head_files: { "app/views/doorkeeper/authorizations/new.html.erb" => "new" },
  expect_specs: %w[
    spec/requests/oauth_authorizations_spec.rb
    spec/requests/oauth_authorize_scope_list_spec.rb
  ],
)

# Other config files must still escalate — the map is per-file, not per-dir.
check(
  "unmapped config file still escalates",
  base_files: { "config/initializers/other.rb" => "old" },
  head_files: { "config/initializers/other.rb" => "new" },
  expect_escalate: true,
)

check(
  "revert decision script, its test, and workflow do not escalate",
  base_files: {
    ".github/workflows/revert-red-main-deploy.yml" => "old",
    "bin/revert-red-main-decision" => "old",
    "spec/bin/revert_red_main_decision_test.rb" => "old",
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
  },
  head_files: {
    ".github/workflows/revert-red-main-deploy.yml" => "new",
    "bin/revert-red-main-decision" => "new",
    "spec/bin/revert_red_main_decision_test.rb" => "new",
    "app/models/widget.rb" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
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

check(
  "main spec-failure classifier, its test, and workflow do not escalate",
  base_files: {
    ".github/workflows/rerun-main-spec-failure.yml" => "old",
    "bin/classify-main-spec-failure" => "old",
    "spec/bin/classify_main_spec_failure_test.rb" => "old",
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
  },
  head_files: {
    ".github/workflows/rerun-main-spec-failure.yml" => "new",
    "bin/classify-main-spec-failure" => "new",
    "spec/bin/classify_main_spec_failure_test.rb" => "new",
    "app/models/widget.rb" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

check(
  "deploy gate and unblock scripts, their tests, and workflow do not escalate",
  base_files: {
    ".github/workflows/deploy-before-main-suite.yml" => "old",
    "bin/deploy-before-main-suite" => "old",
    "bin/deploy-before-main-suite-gate" => "old",
    "spec/bin/deploy_before_main_suite_gate_test.rb" => "old",
    "bin/unblock-buildkite-deploy" => "old",
    "spec/bin/unblock_buildkite_deploy_test.rb" => "old",
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
  },
  head_files: {
    ".github/workflows/deploy-before-main-suite.yml" => "new",
    "bin/deploy-before-main-suite" => "new",
    "bin/deploy-before-main-suite-gate" => "new",
    "spec/bin/deploy_before_main_suite_gate_test.rb" => "new",
    "bin/unblock-buildkite-deploy" => "new",
    "spec/bin/unblock_buildkite_deploy_test.rb" => "new",
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

# Harvest 2026-09-12: recurring run-all-specs gaps.
check(
  "Payouts page fans out to balance request specs (#7438)",
  base_files: {
    "spec/requests/balance_pages_spec.rb" => SPEC_STUB,
    "app/javascript/pages/Payouts/Index.tsx" => "old",
    "app/javascript/components/Payouts/index.tsx" => "old",
  },
  head_files: {
    "app/javascript/pages/Payouts/Index.tsx" => "new",
    "app/javascript/components/Payouts/index.tsx" => "new",
  },
  expect_specs: %w[spec/requests/balance_pages_spec.rb],
)

check(
  "Settings PaymentsPage component fans out to settings request specs (#7473)",
  base_files: {
    "spec/requests/settings/payments_spec.rb" => SPEC_STUB,
    "app/javascript/components/Settings/PaymentsPage/PayPalEmailSection.tsx" => "old",
  },
  head_files: {
    "app/javascript/components/Settings/PaymentsPage/PayPalEmailSection.tsx" => "new",
  },
  expect_specs: %w[spec/requests/settings/payments_spec.rb],
)

check(
  "Emails page fans out to emails request specs (#7578)",
  base_files: {
    "spec/requests/emails/list_spec.rb" => SPEC_STUB,
    "app/javascript/pages/Emails/Published.tsx" => "old",
  },
  head_files: { "app/javascript/pages/Emails/Published.tsx" => "new" },
  expect_specs: %w[spec/requests/emails/list_spec.rb],
)

check(
  "help_center articles.yml maps to help center + API/search specs (#7375)",
  base_files: {
    "spec/requests/help_center_spec.rb" => SPEC_STUB,
    "spec/services/help_center/article_text_spec.rb" => SPEC_STUB,
    "spec/controllers/api/v2/help_articles_controller_spec.rb" => SPEC_STUB,
    "app/models/help_center/articles.yml" => "old",
  },
  head_files: { "app/models/help_center/articles.yml" => "new" },
  expect_specs: %w[
    spec/requests/help_center_spec.rb
    spec/services/help_center/article_text_spec.rb
    spec/controllers/api/v2/help_articles_controller_spec.rb
  ],
)

check(
  "currencies.json still escalates (boot-global pricing registry)",
  base_files: {
    "spec/config/currencies_spec.rb" => SPEC_STUB,
    "config/currencies.json" => "{}",
  },
  head_files: { "config/currencies.json" => "{\"USD\":{}}" },
  expect_escalate: true,
)

check(
  "secure_headers initializer still escalates (global CSP)",
  base_files: {
    "spec/config/initializers/secure_headers_spec.rb" => SPEC_STUB,
    "config/initializers/secure_headers.rb" => "old",
  },
  head_files: { "config/initializers/secure_headers.rb" => "new" },
  expect_escalate: true,
)

check(
  "Tiptap extension still escalates (shared editor, multi-flow consumers)",
  base_files: {
    "spec/requests/products/edit/rich_text_editor_spec.rb" => SPEC_STUB,
    "app/javascript/components/TiptapExtensions/Link.tsx" => "old",
  },
  head_files: { "app/javascript/components/TiptapExtensions/Link.tsx" => "new" },
  expect_escalate: true,
)

check(
  "RichTextEditor still escalates (importer-complete union exceeds 120)",
  base_files: { "app/javascript/components/RichTextEditor.tsx" => "old" },
  head_files: { "app/javascript/components/RichTextEditor.tsx" => "new" },
  expect_escalate: true,
)

check(
  "ImageUploader still escalates (product + profile + bundle consumers)",
  base_files: { "app/javascript/components/ImageUploader.tsx" => "old" },
  head_files: { "app/javascript/components/ImageUploader.tsx" => "new" },
  expect_escalate: true,
)

check(
  "docker nginx with a mapped spec does not escalate (#7468)",
  base_files: {
    "app/models/widget.rb" => "old",
    "spec/models/widget_spec.rb" => SPEC_STUB,
    "docker/nginx/nginx.conf" => "old",
  },
  head_files: {
    "app/models/widget.rb" => "new",
    "docker/nginx/nginx.conf" => "new",
  },
  expect_specs: %w[spec/models/widget_spec.rb],
)

check(
  "docker production server.sh-only change does not escalate (#7260)",
  base_files: { "docker/web/server.sh" => "old" },
  head_files: { "docker/web/server.sh" => "new" },
  expect_specs: [],
)

check(
  "buildkite deploy script-only change does not escalate",
  base_files: { ".buildkite/scripts/preview_asset_cache.sh" => "old" },
  head_files: { ".buildkite/scripts/preview_asset_cache.sh" => "new" },
  expect_specs: [],
)

check(
  "docker nginx-only change does not escalate",
  base_files: { "docker/nginx/nginx.conf" => "old" },
  head_files: { "docker/nginx/nginx.conf" => "new" },
  expect_specs: [],
)

check(
  "docker compose-test change still escalates",
  base_files: { "docker/docker-compose-test-and-ci.yml" => "old" },
  head_files: { "docker/docker-compose-test-and-ci.yml" => "new" },
  expect_escalate: true,
)

check(
  "docker test-image Dockerfile.test escalates (feeds CI rspec image)",
  base_files: { "docker/web/Dockerfile.test" => "old" },
  head_files: { "docker/web/Dockerfile.test" => "new" },
  expect_escalate: true,
)

check(
  "docker ci restore_test_db change still escalates",
  base_files: { "docker/ci/restore_test_db.sh" => "old" },
  head_files: { "docker/ci/restore_test_db.sh" => "new" },
  expect_escalate: true,
)

check(
  "docker fixture manifest escalates (feeds stamp_spec MinIO copies)",
  base_files: { "docker/fixture-files-private.txt" => "old" },
  head_files: { "docker/fixture-files-private.txt" => "new" },
  expect_escalate: true,
)

check(
  "domain.rb still escalates even when domain_spec exists",
  base_files: {
    "spec/config/domain_spec.rb" => SPEC_STUB,
    "config/domain.rb" => "old",
  },
  head_files: { "config/domain.rb" => "new" },
  expect_escalate: true,
)

check(
  "email stylesheet still escalates (mailers plus receipt-preview renderer)",
  base_files: { "app/javascript/stylesheets/_email.scss" => "old" },
  head_files: { "app/javascript/stylesheets/_email.scss" => "new" },
  expect_escalate: true,
)

check(
  "profile parser still escalates (Coffee + product profile + settings consumers)",
  base_files: { "app/javascript/parsers/profile.ts" => "old" },
  head_files: { "app/javascript/parsers/profile.ts" => "new" },
  expect_escalate: true,
)

# Negatives harvested as unsafe to map.
check(
  "shared Select.tsx still escalates (#7437)",
  base_files: { "app/javascript/components/Select.tsx" => "old" },
  head_files: { "app/javascript/components/Select.tsx" => "new" },
  expect_escalate: true,
)

check(
  "ui/Select.tsx still escalates (imported from checkout+payouts+settings)",
  base_files: { "app/javascript/components/ui/Select.tsx" => "old" },
  head_files: { "app/javascript/components/ui/Select.tsx" => "new" },
  expect_escalate: true,
)

check(
  "routes.rb still escalates",
  base_files: { "config/routes.rb" => "old" },
  head_files: { "config/routes.rb" => "new" },
  expect_escalate: true,
)

check(
  "sidekiq_schedule.yml still escalates",
  base_files: { "config/sidekiq_schedule.yml" => "old" },
  head_files: { "config/sidekiq_schedule.yml" => "new" },
  expect_escalate: true,
)

check(
  "application.rb still escalates",
  base_files: { "config/application.rb" => "old" },
  head_files: { "config/application.rb" => "new" },
  expect_escalate: true,
)

# #7070 post-merge miss: checkout presenter must still pull checkout flow specs.
check(
  "checkout presenter still fans out to checkout request specs (#7070)",
  base_files: {
    "spec/requests/checkout/payment_spec.rb" => SPEC_STUB,
    "spec/requests/purchases/product_spec.rb" => SPEC_STUB,
    "spec/requests/subscription/non_tiered_membership_spec.rb" => SPEC_STUB,
    "app/presenters/checkout/stripe_payment_presenter.rb" => "old",
  },
  head_files: { "app/presenters/checkout/stripe_payment_presenter.rb" => "new" },
  expect_specs: %w[
    spec/requests/checkout/payment_spec.rb
    spec/requests/purchases/product_spec.rb
    spec/requests/subscription/non_tiered_membership_spec.rb
  ],
)

# Importer-traced pins (round 2). Each asserts a consuming flow's spec,
# not a coincidental sibling path from a harvested PR.
check(
  "data/paypal selects checkout payment spec, not settings",
  base_files: {
    "spec/requests/checkout/payment_spec.rb" => SPEC_STUB,
    "spec/requests/settings/payments_spec.rb" => SPEC_STUB,
    "app/javascript/data/paypal.ts" => "old",
  },
  head_files: { "app/javascript/data/paypal.ts" => "new" },
  expect_specs: %w[spec/requests/checkout/payment_spec.rb],
)

check(
  "custom_html_analytics selects buyer custom-HTML specs, not seller analytics",
  base_files: {
    "spec/requests/products/show/custom_html_analytics_spec.rb" => SPEC_STUB,
    "spec/requests/profile_custom_html_spec.rb" => SPEC_STUB,
    "spec/requests/profile_analytics_spec.rb" => SPEC_STUB,
    "spec/requests/analytics/sales_spec.rb" => SPEC_STUB,
    "app/javascript/entrypoints/custom_html_analytics.ts" => "old",
  },
  head_files: { "app/javascript/entrypoints/custom_html_analytics.ts" => "new" },
  expect_specs: %w[
    spec/requests/products/show/custom_html_analytics_spec.rb
    spec/requests/profile_custom_html_spec.rb
    spec/requests/profile_analytics_spec.rb
  ],
)

check(
  "pages/UrlRedirects/DownloadPage selects download_page plus reading/video specs",
  base_files: {
    "spec/requests/download_page/download_page_spec.rb" => SPEC_STUB,
    "spec/requests/reading_spec.rb" => SPEC_STUB,
    "spec/requests/video_streaming_spec.rb" => SPEC_STUB,
    "spec/requests/url_redirects_epub_reader_system_spec.rb" => SPEC_STUB,
    "app/javascript/pages/UrlRedirects/DownloadPage.tsx" => "old",
  },
  head_files: { "app/javascript/pages/UrlRedirects/DownloadPage.tsx" => "new" },
  expect_specs: %w[
    spec/requests/download_page/download_page_spec.rb
    spec/requests/reading_spec.rb
    spec/requests/video_streaming_spec.rb
  ],
)

# A shared-component directory maps as a whole; a file whose consumers leave
# that mapping escalates. Layout renders the UrlRedirects pages; WithContent
# reaches ProductEdit/ContentTab through components/Download/{RichContent,FileList}.
check(
  "components/DownloadPage keeps its directory mapping for a file with no outside consumer",
  base_files: {
    "spec/requests/download_page/download_page_spec.rb" => SPEC_STUB,
    "app/javascript/components/DownloadPage/AudioPlayerContainer.tsx" => "old",
  },
  head_files: { "app/javascript/components/DownloadPage/AudioPlayerContainer.tsx" => "new" },
  expect_specs: %w[spec/requests/download_page/download_page_spec.rb],
)

check(
  "components/DownloadPage/Layout escalates even with a co-located vitest",
  base_files: {
    "spec/requests/download_page/download_page_spec.rb" => SPEC_STUB,
    "app/javascript/components/DownloadPage/Layout.tsx" => "old",
    "app/javascript/components/DownloadPage/Layout.test.tsx" => "old test",
  },
  head_files: { "app/javascript/components/DownloadPage/Layout.tsx" => "new" },
  expect_escalate: true,
)

check(
  "components/DownloadPage/WithContent escalates even with a co-located vitest",
  base_files: {
    "spec/requests/download_page/download_page_spec.rb" => SPEC_STUB,
    "app/javascript/components/DownloadPage/WithContent.tsx" => "old",
    "app/javascript/components/DownloadPage/WithContent.test.tsx" => "old test",
  },
  head_files: { "app/javascript/components/DownloadPage/WithContent.tsx" => "new" },
  expect_escalate: true,
)

# One check per block, so a name that stops matching the mapping fails on its own.
%w[LicenseKey ShortAnswer LongAnswer TextInputNodeView FileUpload Posts MoreLikeThis].each do |block|
  check(
    "content-only editor block #{block} selects the product and download specs",
    base_files: {
      "spec/requests/products/edit/rich_text_editor_spec.rb" => SPEC_STUB,
      "spec/requests/products/show/show_spec.rb" => SPEC_STUB,
      "spec/requests/download_page/download_page_spec.rb" => SPEC_STUB,
      "spec/requests/reading_spec.rb" => SPEC_STUB,
      "spec/requests/video_streaming_spec.rb" => SPEC_STUB,
      "app/javascript/components/TiptapExtensions/#{block}.tsx" => "old",
    },
    head_files: { "app/javascript/components/TiptapExtensions/#{block}.tsx" => "new" },
    expect_specs: %w[
      spec/requests/download_page/download_page_spec.rb
      spec/requests/products/edit/rich_text_editor_spec.rb
      spec/requests/products/show/show_spec.rb
      spec/requests/reading_spec.rb
      spec/requests/video_streaming_spec.rb
    ],
  )
end

check(
  "pages/UrlRedirects/Read escalates even with its co-located vitest",
  base_files: {
    "app/javascript/pages/UrlRedirects/Read.tsx" => "old",
    "app/javascript/pages/UrlRedirects/Read.test.tsx" => "old test",
  },
  head_files: { "app/javascript/pages/UrlRedirects/Read.tsx" => "new" },
  expect_escalate: true,
)

# The escalation above must not spread: a module with no mapping and a
# co-located vitest is still covered by vitest alone (lint_js runs npm test).
check(
  "a leaf component with a co-located vitest still rides the vitest shortcut",
  base_files: {
    "app/javascript/components/TipButton/TipButton.tsx" => "old",
    "app/javascript/components/TipButton/TipButton.test.tsx" => "old test",
  },
  head_files: { "app/javascript/components/TipButton/TipButton.tsx" => "new" },
  expect_escalate: false,
)

check(
  "pages/Pages selects pages_controller and landing embed specs",
  base_files: {
    "spec/controllers/pages_controller_spec.rb" => SPEC_STUB,
    "spec/requests/pages_landing_embed_csp_spec.rb" => SPEC_STUB,
    "app/javascript/pages/Pages/Edit.tsx" => "old",
  },
  head_files: { "app/javascript/pages/Pages/Edit.tsx" => "new" },
  expect_specs: %w[
    spec/controllers/pages_controller_spec.rb
    spec/requests/pages_landing_embed_csp_spec.rb
  ],
)

check(
  "unlisted pages dir still escalates (generic name-match dropped)",
  base_files: { "app/javascript/pages/Signup/New.tsx" => "old" },
  head_files: { "app/javascript/pages/Signup/New.tsx" => "new" },
  expect_escalate: true,
)

check(
  "ReviewForm still escalates (editor + purchase + library consumers)",
  base_files: { "app/javascript/components/ReviewForm.tsx" => "old" },
  head_files: { "app/javascript/components/ReviewForm.tsx" => "new" },
  expect_escalate: true,
)

check(
  "DiscordButton selects checkout receipt coverage",
  base_files: {
    "spec/requests/download_page/download_page_spec.rb" => SPEC_STUB,
    "spec/requests/checkout/payment_spec.rb" => SPEC_STUB,
    "app/javascript/components/DiscordButton.tsx" => "old",
  },
  head_files: { "app/javascript/components/DiscordButton.tsx" => "new" },
  expect_specs: %w[
    spec/requests/download_page/download_page_spec.rb
    spec/requests/checkout/payment_spec.rb
  ],
)

check(
  "discord_integration selects product edit integrations spec",
  base_files: {
    "spec/requests/download_page/download_page_spec.rb" => SPEC_STUB,
    "spec/requests/products/edit/integrations/discord_integrations_spec.rb" => SPEC_STUB,
    "app/javascript/data/discord_integration.ts" => "old",
  },
  head_files: { "app/javascript/data/discord_integration.ts" => "new" },
  expect_specs: %w[spec/requests/products/edit/integrations/discord_integrations_spec.rb],
)

check(
  "ReviewVideoPlayer still escalates (editor + purchase + customers consumers)",
  base_files: { "app/javascript/components/ReviewVideoPlayer.tsx" => "old" },
  head_files: { "app/javascript/components/ReviewVideoPlayer.tsx" => "new" },
  expect_escalate: true,
)

check(
  "data/product_reviews still escalates (editor + purchase consumers)",
  base_files: { "app/javascript/data/product_reviews.ts" => "old" },
  head_files: { "app/javascript/data/product_reviews.ts" => "new" },
  expect_escalate: true,
)

check(
  "DateRangePicker still escalates (analytics + customers consumers)",
  base_files: { "app/javascript/components/DateRangePicker.tsx" => "old" },
  head_files: { "app/javascript/components/DateRangePicker.tsx" => "new" },
  expect_escalate: true,
)

check(
  "useRecaptcha still escalates (checkout + profile follow consumers)",
  base_files: { "app/javascript/components/useRecaptcha.tsx" => "old" },
  head_files: { "app/javascript/components/useRecaptcha.tsx" => "new" },
  expect_escalate: true,
)

check(
  "data/search still escalates (discover + storefront editor consumers)",
  base_files: { "app/javascript/data/search.ts" => "old" },
  head_files: { "app/javascript/data/search.ts" => "new" },
  expect_escalate: true,
)

check(
  "Settings ApplicationForm also selects oauth applications pages spec",
  base_files: {
    "spec/requests/settings/payments_spec.rb" => SPEC_STUB,
    "spec/requests/oauth_applications_pages_spec.rb" => SPEC_STUB,
    "app/javascript/components/Settings/AdvancedPage/ApplicationForm.tsx" => "old",
  },
  head_files: { "app/javascript/components/Settings/AdvancedPage/ApplicationForm.tsx" => "new" },
  expect_specs: %w[spec/requests/oauth_applications_pages_spec.rb],
)

check(
  "Settings Layout selects account confirmation spec",
  base_files: {
    "spec/requests/settings/payments_spec.rb" => SPEC_STUB,
    "spec/requests/account_confirmation_spec.rb" => SPEC_STUB,
    "app/javascript/components/Settings/Layout.tsx" => "old",
  },
  head_files: { "app/javascript/components/Settings/Layout.tsx" => "new" },
  expect_specs: %w[spec/requests/account_confirmation_spec.rb],
)

check(
  "Settings PasskeysSection selects passkey login spec",
  base_files: {
    "spec/requests/settings/payments_spec.rb" => SPEC_STUB,
    "spec/requests/login/passkeys_spec.rb" => SPEC_STUB,
    "app/javascript/components/Settings/PasswordPage/PasskeysSection.tsx" => "old",
  },
  head_files: { "app/javascript/components/Settings/PasswordPage/PasskeysSection.tsx" => "new" },
  expect_specs: %w[spec/requests/login/passkeys_spec.rb],
)

check(
  "EmailsPage Layout selects followers specs",
  base_files: {
    "spec/requests/emails/list_spec.rb" => SPEC_STUB,
    "spec/requests/followers/followers_spec.rb" => SPEC_STUB,
    "app/javascript/components/EmailsPage/Layout.tsx" => "old",
  },
  head_files: { "app/javascript/components/EmailsPage/Layout.tsx" => "new" },
  expect_specs: %w[
    spec/requests/emails/list_spec.rb
    spec/requests/followers/followers_spec.rb
  ],
)

check(
  "Users/Coffee selects purchase coffee spec and tipping spec",
  base_files: {
    "spec/requests/user/profile_spec.rb" => SPEC_STUB,
    "spec/requests/purchases/product/coffee_spec.rb" => SPEC_STUB,
    "spec/requests/purchases/tipping_spec.rb" => SPEC_STUB,
    "app/javascript/pages/Users/Coffee.tsx" => "old",
  },
  head_files: { "app/javascript/pages/Users/Coffee.tsx" => "new" },
  expect_specs: %w[
    spec/requests/purchases/product/coffee_spec.rb
    spec/requests/purchases/tipping_spec.rb
  ],
)

check(
  "Users/Show still escalates (UTM checkout consumer)",
  base_files: { "app/javascript/pages/Users/Show.tsx" => "old" },
  head_files: { "app/javascript/pages/Users/Show.tsx" => "new" },
  expect_escalate: true,
)

check(
  "Users/ReviewReminders still escalates (not storefront)",
  base_files: { "app/javascript/pages/Users/ReviewReminders/Unsubscribe.tsx" => "old" },
  head_files: { "app/javascript/pages/Users/ReviewReminders/Unsubscribe.tsx" => "new" },
  expect_escalate: true,
)

check(
  "Users/SubscribePreview still escalates (preview generator, not storefront list)",
  base_files: { "app/javascript/pages/Users/SubscribePreview.tsx" => "old" },
  head_files: { "app/javascript/pages/Users/SubscribePreview.tsx" => "new" },
  expect_escalate: true,
)

check(
  "Followers/Cancel still escalates (buyer unsubscribe, not seller list)",
  base_files: { "app/javascript/pages/Followers/Cancel.tsx" => "old" },
  head_files: { "app/javascript/pages/Followers/Cancel.tsx" => "new" },
  expect_escalate: true,
)

check(
  "Dashboard page still escalates (auth and Agent visitors)",
  base_files: { "app/javascript/pages/Dashboard/Index.tsx" => "old" },
  head_files: { "app/javascript/pages/Dashboard/Index.tsx" => "new" },
  expect_escalate: true,
)

check(
  "Wishlists/Show still escalates (Discover purchase/commission consumer)",
  base_files: { "app/javascript/pages/Wishlists/Show.tsx" => "old" },
  head_files: { "app/javascript/pages/Wishlists/Show.tsx" => "new" },
  expect_escalate: true,
)

check(
  "User/Passwords selects password_reset spec, not generic user/",
  base_files: {
    "spec/requests/password_reset_spec.rb" => SPEC_STUB,
    "spec/requests/login_spec.rb" => SPEC_STUB,
    "spec/requests/user/profile_spec.rb" => SPEC_STUB,
    "app/javascript/pages/User/Passwords/Edit.tsx" => "old",
  },
  head_files: { "app/javascript/pages/User/Passwords/Edit.tsx" => "new" },
  expect_specs: %w[
    spec/requests/password_reset_spec.rb
    spec/requests/login_spec.rb
  ],
)

check(
  "config/domain.rb still escalates (boot-global hosts)",
  base_files: {
    "spec/config/domain_spec.rb" => SPEC_STUB,
    "config/domain.rb" => "old",
  },
  head_files: { "config/domain.rb" => "new" },
  expect_escalate: true,
)

check(
  "config/test_redis_isolation.rb still escalates (required from application.rb)",
  base_files: {
    "spec/config/test_redis_isolation_spec.rb" => SPEC_STUB,
    "config/test_redis_isolation.rb" => "old",
  },
  head_files: { "config/test_redis_isolation.rb" => "new" },
  expect_escalate: true,
)

check(
  "005_apple.rb still escalates (global OmniAuth strategy)",
  base_files: {
    "spec/config/initializers/apple_strategy_patch_spec.rb" => SPEC_STUB,
    "config/initializers/005_apple.rb" => "old",
  },
  head_files: { "config/initializers/005_apple.rb" => "new" },
  expect_escalate: true,
)

check(
  "alterity initializer maps to alterity_spec instead of escalating",
  base_files: {
    "spec/config/initializers/alterity_spec.rb" => SPEC_STUB,
    "config/initializers/alterity.rb" => "old",
  },
  head_files: { "config/initializers/alterity.rb" => "new" },
  expect_specs: %w[spec/config/initializers/alterity_spec.rb],
)

check(
  "instant_ddl_first initializer maps to its dedicated spec",
  base_files: {
    "spec/config/initializers/instant_ddl_first_spec.rb" => SPEC_STUB,
    "config/initializers/instant_ddl_first.rb" => "old",
  },
  head_files: { "config/initializers/instant_ddl_first.rb" => "new" },
  expect_specs: %w[spec/config/initializers/instant_ddl_first_spec.rb],
)

check(
  "active_storage_jobs initializer maps to its dedicated spec",
  base_files: {
    "spec/config/initializers/active_storage_jobs_spec.rb" => SPEC_STUB,
    "config/initializers/active_storage_jobs.rb" => "old",
  },
  head_files: { "config/initializers/active_storage_jobs.rb" => "new" },
  expect_specs: %w[spec/config/initializers/active_storage_jobs_spec.rb],
)

check(
  "devise_pwned_password_safe_params still escalates (Warden after_set_user)",
  base_files: {
    "spec/config/initializers/devise_pwned_password_safe_params_spec.rb" => SPEC_STUB,
    "config/initializers/devise_pwned_password_safe_params.rb" => "old",
  },
  head_files: { "config/initializers/devise_pwned_password_safe_params.rb" => "new" },
  expect_escalate: true,
)

# Deleted spec files have nothing left to run. The rest of the diff still maps.
check(
  "deleted spec files do not escalate alongside a mapped spec edit",
  base_files: {
    "spec/models/discover_search_spec.rb" => SPEC_STUB,
    "spec/sidekiq/refresh_sitemap_daily_worker_spec.rb" => SPEC_STUB,
  },
  head_files: { "spec/sidekiq/refresh_sitemap_daily_worker_spec.rb" => "# edited\n" },
  head_deletes: %w[spec/models/discover_search_spec.rb],
  expect_specs: %w[spec/sidekiq/refresh_sitemap_daily_worker_spec.rb],
)

check(
  "a diff that only deletes spec files selects nothing",
  base_files: {
    "spec/models/discover_search_spec.rb" => SPEC_STUB,
    "spec/models/sales_export_chunk_spec.rb" => SPEC_STUB,
  },
  head_files: {},
  head_deletes: %w[spec/models/discover_search_spec.rb spec/models/sales_export_chunk_spec.rb],
  expect_specs: [],
)

check(
  "deleted app code still escalates when its spec is deleted with it",
  base_files: {
    "lib/utilities/xml_helpers.rb" => "module XmlHelpers; end\n",
    "spec/lib/utilities/xml_helpers_spec.rb" => SPEC_STUB,
  },
  head_files: {},
  head_deletes: %w[lib/utilities/xml_helpers.rb spec/lib/utilities/xml_helpers_spec.rb],
  expect_escalate: true,
)

check(
  "a deleted spec support file still escalates",
  base_files: { "spec/support/some_helper.rb" => "# helper\n" },
  head_files: {},
  head_deletes: %w[spec/support/some_helper.rb],
  expect_escalate: true,
)

# Purely additive migrations map to the specs that name their tables; any other
# db/ change keeps escalating. Escalate cases assert the reason, so they fail
# against a selector that escalates every db/ path for the old reason.
WIDGET_SPEC = "# frozen_string_literal: true\n\nRSpec.describe Widget do\nend\n"
WIDGETS_REQUEST_SPEC = "# frozen_string_literal: true\n\nRSpec.describe \"widgets\" do\nend\n"
UNRELATED_SPEC = "# frozen_string_literal: true\n\nRSpec.describe Unrelated do\nend\n"
DB_SPECS = {
  "spec/models/widget_spec.rb" => WIDGET_SPEC,
  "spec/requests/widgets_spec.rb" => WIDGETS_REQUEST_SPEC,
  "spec/models/unrelated_spec.rb" => UNRELATED_SPEC,
}.freeze
WIDGET_SPECS = %w[spec/models/widget_spec.rb spec/requests/widgets_spec.rb].freeze
ADDITIVE_REASON = "is not a purely additive migration"
MIGRATION_PATH_FOR_TEST = "db/migrate/20261216120002_change_widgets.rb"

def migration_rb(methods, superclass: "ActiveRecord::Migration[8.1]")
  "# frozen_string_literal: true\n\nclass ChangeWidgets < #{superclass}\n#{methods}end\n"
end

def schema_rb(version: "2026_12_16_120001", widget_columns: [], gadget_columns: [], extra_tables: "")
  out = +"# comment\n\nActiveRecord::Schema[7.1].define(version: #{version}) do\n"
  out << %(  create_table "widgets", charset: "utf8mb4" do |t|\n    t.string "name"\n)
  widget_columns.each { |column| out << "    #{column}\n" }
  out << %(    t.index ["name"], name: "index_widgets_on_name"\n  end\n\n)
  out << %(  create_table "gadgets", charset: "utf8mb4" do |t|\n    t.string "kind"\n)
  gadget_columns.each { |column| out << "    #{column}\n" }
  out << "  end\n#{extra_tables}end\n"
end

def additive_check(name, body, schema: nil, **options)
  base_files = DB_SPECS.merge("db/schema.rb" => schema_rb)
  head_files = { MIGRATION_PATH_FOR_TEST => migration_rb(body) }
  head_files["db/schema.rb"] = schema if schema
  check(name, base_files:, head_files:, expect_specs: WIDGET_SPECS, reject_specs: %w[spec/models/unrelated_spec.rb], **options)
end

def non_additive_check(name, body, reason: ADDITIVE_REASON, schema: nil)
  head_files = { MIGRATION_PATH_FOR_TEST => migration_rb(body) }
  head_files["db/schema.rb"] = schema if schema
  check(name, base_files: DB_SPECS.merge("db/schema.rb" => schema_rb), head_files:, expect_escalate: true, expect_reason: reason)
end

WIDGET_SCHEMA = schema_rb(version: "2026_12_16_120002", widget_columns: [%(t.string "border_radius")])

additive_check(
  "additive change_table migration maps to specs naming the model and the table",
  "  def change\n    change_table :widgets, bulk: true do |t|\n      t.string :border_radius\n    end\n  end\n",
  schema: WIDGET_SCHEMA,
)

additive_check(
  "additive add_column migration maps to specs naming the table",
  "  def change\n    add_column :widgets, :border_radius, :string\n  end\n",
  schema: WIDGET_SCHEMA,
)

additive_check(
  "add_column in parentheses with a NOT NULL default is additive",
  "  def change\n    add_column(:widgets, :border_radius, :integer, null: false, default: 0, limit: 2)\n  end\n",
  schema: WIDGET_SCHEMA,
)

additive_check(
  "additive add_index migration maps to specs naming the table",
  "  def change\n    add_index :widgets, [:name, :kind], name: \"index_widgets_on_name_and_kind\"\n  end\n",
  schema: schema_rb(version: "2026_12_16_120002", widget_columns: [%(t.index ["name", "kind"], name: "index_widgets_on_name_and_kind")]),
)

additive_check(
  "additive up-only migration maps to specs naming the table",
  "  def up\n    add_column :widgets, :border_radius, :string\n  end\n",
  schema: WIDGET_SCHEMA,
)

additive_check(
  "additive migration without a schema.rb change is accepted",
  "  def change\n    add_column :widgets, :border_radius, :string\n  end\n",
)

additive_check(
  "additive change_table migration with an index and a nullable reference is accepted",
  "  def change\n    change_table :widgets do |t|\n      t.references :owner\n      t.index :owner_id\n    end\n  end\n",
  schema: schema_rb(version: "2026_12_16_120002", widget_columns: [%(t.bigint "owner_id"), %(t.index ["owner_id"], name: "index_widgets_on_owner_id")]),
)

check(
  "additive create_table migration maps to specs naming the new model, with its schema block",
  base_files: {
    "spec/models/thing_spec.rb" => "# frozen_string_literal: true\n\nRSpec.describe Thing do\nend\n",
    "spec/models/unrelated_spec.rb" => UNRELATED_SPEC,
    "db/schema.rb" => schema_rb,
  },
  head_files: {
    "db/migrate/20261216120002_create_things.rb" => migration_rb(
      "  def change\n    create_table :things do |t|\n      t.string :name, null: false\n      t.index :name, unique: true\n      t.timestamps\n    end\n  end\n",
    ),
    "db/schema.rb" => schema_rb(
      version: "2026_12_16_120002",
      extra_tables: %(\n  create_table "things", charset: "utf8mb4" do |t|\n    t.string "name", null: false\n    t.datetime "created_at", null: false\n    t.index ["name"], name: "index_things_on_name", unique: true\n  end\n),
    ),
  },
  expect_specs: %w[spec/models/thing_spec.rb],
  reject_specs: %w[spec/models/unrelated_spec.rb],
)

check(
  "plural table name maps to specs naming the singular model",
  base_files: {
    "spec/models/category_spec.rb" => "# frozen_string_literal: true\n\nRSpec.describe Category do\nend\n",
    "spec/models/unrelated_spec.rb" => UNRELATED_SPEC,
  },
  head_files: { "db/migrate/20261216120002_add_slug_to_categories.rb" => migration_rb("  def change\n    add_column :categories, :slug, :string\n  end\n") },
  expect_specs: %w[spec/models/category_spec.rb],
  reject_specs: %w[spec/models/unrelated_spec.rb],
)

non_additive_check("migration that removes a column escalates", "  def change\n    remove_column :widgets, :name, :string\n  end\n")
non_additive_check("migration that renames a column escalates", "  def change\n    rename_column :widgets, :name, :title\n  end\n")
non_additive_check("migration that changes a column escalates", "  def change\n    change_column :widgets, :name, :text\n  end\n")
non_additive_check("migration that drops a table escalates", "  def change\n    drop_table :widgets\n  end\n")
non_additive_check("migration that runs execute escalates", "  def up\n    execute \"UPDATE widgets SET name = 'x'\"\n  end\n")
non_additive_check(
  "migration with an update of existing rows escalates",
  "  def change\n    add_column :widgets, :label, :string\n    Widget.update_all(label: \"x\")\n  end\n",
)
non_additive_check(
  "migration with reversible escalates",
  "  def change\n    reversible do |direction|\n      direction.up { add_column :widgets, :label, :string }\n    end\n  end\n",
)
non_additive_check(
  "migration with an up and a down method escalates",
  "  def up\n    add_column :widgets, :label, :string\n  end\n\n  def down\n    remove_column :widgets, :label\n  end\n",
)
non_additive_check(
  "migration with one removal next to an addition escalates",
  "  def change\n    add_column :widgets, :label, :string\n    remove_column :widgets, :name, :string\n  end\n",
)
non_additive_check(
  "change_table that removes a column escalates",
  "  def change\n    change_table :widgets, bulk: true do |t|\n      t.string :label\n      t.remove :name\n    end\n  end\n",
)
non_additive_check(
  "change_table that changes a column escalates",
  "  def change\n    change_table :widgets do |t|\n      t.change :name, :text\n    end\n  end\n",
)
non_additive_check(
  "change_table that renames a column escalates",
  "  def change\n    change_table :widgets do |t|\n      t.rename :name, :title\n    end\n  end\n",
)
non_additive_check(
  "create_table with force escalates",
  "  def change\n    create_table :widgets, force: true do |t|\n      t.string :name\n    end\n  end\n",
)
non_additive_check(
  "add_column with a default computed by code escalates",
  "  def change\n    add_column :widgets, :label, :string, default: Widget.default_label\n  end\n",
)
non_additive_check(
  "add_column with an interpolated default escalates",
  "  def change\n    add_column :widgets, :label, :string, default: \"a\#{1}\"\n  end\n",
)
non_additive_check(
  "add_column that is NOT NULL without a default escalates",
  "  def change\n    add_column :widgets, :label, :string, null: false\n  end\n",
)
non_additive_check(
  "change_table column that is NOT NULL without a default escalates",
  "  def change\n    change_table :widgets do |t|\n      t.string :label, null: false\n    end\n  end\n",
)
non_additive_check(
  "add_column called on a receiver escalates",
  "  def change\n    SomeHelper.add_column(:widgets, :label, :string)\n  end\n",
)
non_additive_check(
  "add_column that is NOT NULL with a nil default escalates",
  "  def change\n    add_column :widgets, :label, :string, null: false, default: nil\n  end\n",
)
non_additive_check(
  "change_table timestamps on an existing table escalates",
  "  def change\n    change_table :widgets do |t|\n      t.timestamps\n    end\n  end\n",
)
non_additive_check(
  "change_table timestamps with NOT NULL escalates",
  "  def change\n    change_table :widgets do |t|\n      t.timestamps null: false\n    end\n  end\n",
)
non_additive_check(
  "unique add_index on an existing table escalates",
  "  def change\n    add_index :widgets, :name, unique: true\n  end\n",
)
non_additive_check(
  "unique index in change_table escalates",
  "  def change\n    change_table :widgets do |t|\n      t.index :name, unique: true\n    end\n  end\n",
)
non_additive_check(
  "change_table column call with a block escalates",
  "  def change\n    change_table :widgets do |t|\n      t.string(:label) { puts 1 }\n    end\n  end\n",
)
non_additive_check(
  "migration with an unknown statement escalates",
  "  def change\n    add_column :widgets, :label, :string\n    say \"done\"\n  end\n",
)
non_additive_check(
  "migration with a helper method next to change escalates",
  "  def change\n    add_column :widgets, :label, :string\n  end\n\n  def helper\n  end\n",
)
check(
  "migration class with a look-alike superclass escalates",
  base_files: DB_SPECS,
  head_files: { MIGRATION_PATH_FOR_TEST => migration_rb("  def change\n    add_column :widgets, :label, :string\n  end\n", superclass: "Other::Migration[8.1]") },
  expect_escalate: true,
  expect_reason: ADDITIVE_REASON,
)
check(
  "migration that does not parse escalates",
  base_files: DB_SPECS,
  head_files: { MIGRATION_PATH_FOR_TEST => "class ChangeWidgets < ActiveRecord::Migration[8.1]\n  def change\n" },
  expect_escalate: true,
  expect_reason: ADDITIVE_REASON,
)
check(
  "deleted migration escalates",
  base_files: DB_SPECS.merge(MIGRATION_PATH_FOR_TEST => migration_rb("  def change\n    add_column :widgets, :label, :string\n  end\n")),
  head_files: { "app/models/widget.rb" => "# noop\n" },
  head_deletes: [MIGRATION_PATH_FOR_TEST],
  expect_escalate: true,
  expect_reason: ADDITIVE_REASON,
)
additive_check(
  "change_table timestamps that allow NULL are accepted on an existing table",
  "  def change\n    change_table :widgets do |t|\n      t.timestamps null: true\n    end\n  end\n",
)

check(
  "migration touching two tables selects the specs of both",
  base_files: DB_SPECS.merge("spec/models/gadget_spec.rb" => "RSpec.describe Gadget do\nend\n"),
  head_files: {
    MIGRATION_PATH_FOR_TEST => migration_rb("  def change\n    add_column :widgets, :label, :string\n    add_column :gadgets, :label, :string\n  end\n"),
  },
  expect_specs: WIDGET_SPECS + %w[spec/models/gadget_spec.rb],
  reject_specs: %w[spec/models/unrelated_spec.rb],
)
check(
  "migration touching two tables escalates when only one table has a spec",
  base_files: DB_SPECS,
  head_files: {
    MIGRATION_PATH_FOR_TEST => migration_rb("  def change\n    add_column :widgets, :label, :string\n    add_column :gadgets, :label, :string\n  end\n"),
  },
  expect_escalate: true,
  expect_reason: "no spec names gadgets",
)
check(
  "additive migration on a table no spec names escalates",
  base_files: { "spec/models/unrelated_spec.rb" => UNRELATED_SPEC },
  head_files: { MIGRATION_PATH_FOR_TEST => migration_rb("  def change\n    add_column :widgets, :label, :string\n  end\n") },
  expect_escalate: true,
  expect_reason: "no spec names widgets",
)
check(
  "additive migration whose specs exceed the file cap escalates",
  base_files: (1..121).to_h { |i| ["spec/models/widget_#{i}_spec.rb", "RSpec.describe Widget do\nend\n"] },
  head_files: { MIGRATION_PATH_FOR_TEST => migration_rb("  def change\n    add_column :widgets, :label, :string\n  end\n") },
  expect_escalate: true,
  expect_reason: "exceeds",
)

SCHEMA_REASON = "changes more than the additive migration's tables"

non_additive_check(
  "schema.rb change in a table the migration does not touch escalates",
  "  def change\n    add_column :widgets, :border_radius, :string\n  end\n",
  schema: schema_rb(version: "2026_12_16_120002", widget_columns: [%(t.string "border_radius")], gadget_columns: [%(t.string "extra")]),
  reason: SCHEMA_REASON,
)
non_additive_check(
  "schema.rb line removed from a touched table escalates",
  "  def change\n    add_column :widgets, :border_radius, :string\n  end\n",
  schema: schema_rb(version: "2026_12_16_120002", widget_columns: [%(t.string "border_radius")]).sub(%(    t.string "name"\n), ""),
  reason: SCHEMA_REASON,
)
non_additive_check(
  "schema.rb foreign key outside a table block escalates",
  "  def change\n    add_column :widgets, :border_radius, :string\n  end\n",
  schema: schema_rb(version: "2026_12_16_120002", widget_columns: [%(t.string "border_radius")]).sub(/^end\n\z/, %(  add_foreign_key "widgets", "gadgets"\nend\n)),
  reason: SCHEMA_REASON,
)
non_additive_check(
  "schema.rb change with a different table header escalates",
  "  def change\n    add_column :widgets, :border_radius, :string\n  end\n",
  schema: schema_rb(version: "2026_12_16_120002", widget_columns: [%(t.string "border_radius")]).sub(%(create_table "widgets", charset: "utf8mb4"), %(create_table "widgets", charset: "latin1")),
  reason: SCHEMA_REASON,
)

check(
  "schema.rb without a migration escalates",
  base_files: DB_SPECS.merge("db/schema.rb" => schema_rb),
  head_files: { "db/schema.rb" => WIDGET_SCHEMA },
  expect_escalate: true,
  expect_reason: "db/schema.rb changed without a migration",
)
check(
  "db/ file that is neither a migration nor schema.rb escalates",
  base_files: DB_SPECS,
  head_files: { "db/seeds.rb" => "puts 1\n" },
  expect_escalate: true,
  expect_reason: "db/seeds.rb is not a migration or db/schema.rb",
)
check(
  "additive migration next to a data migration escalates",
  base_files: DB_SPECS,
  head_files: {
    MIGRATION_PATH_FOR_TEST => migration_rb("  def change\n    add_column :widgets, :label, :string\n  end\n"),
    "db/data/20261216120003_backfill_widgets.rb" => "# noop\n",
  },
  expect_escalate: true,
  expect_reason: "db/data/20261216120003_backfill_widgets.rb is not a migration or db/schema.rb",
)
check(
  "additive migration next to an unmapped file escalates on the file",
  base_files: DB_SPECS.merge("app/javascript/stylesheets/tailwind.css" => "old"),
  head_files: {
    MIGRATION_PATH_FOR_TEST => migration_rb("  def change\n    add_column :widgets, :label, :string\n  end\n"),
    "app/javascript/stylesheets/tailwind.css" => "new",
  },
  expect_escalate: true,
  expect_reason: "diff touches app/javascript/stylesheets/tailwind.css but no specs",
)

# The custom_styles template renders only through SellerProfile#custom_styles,
# so the specs that name custom_styles cover it.
check(
  "custom_styles template maps to the specs that name custom_styles",
  base_files: {
    "spec/models/seller_profile_spec.rb" => "expect(subject.custom_styles).to include(\"--accent\")\n",
    "spec/controllers/checkout_controller_spec.rb" => "expect(css).to eq(profile.custom_styles)\n",
    "spec/models/unrelated_spec.rb" => UNRELATED_SPEC,
    "app/views/layouts/custom_styles/styles.scss.erb" => "old",
  },
  head_files: { "app/views/layouts/custom_styles/styles.scss.erb" => "new" },
  expect_specs: %w[spec/models/seller_profile_spec.rb spec/controllers/checkout_controller_spec.rb],
  reject_specs: %w[spec/models/unrelated_spec.rb],
)
check(
  "custom_styles partial is not mapped by the template rule",
  base_files: {
    "spec/models/seller_profile_spec.rb" => "expect(subject.custom_styles).to be_present\n",
    "app/views/layouts/custom_styles/_style.html.erb" => "old",
    "app/views/layouts/custom_styles/styles.scss.erb" => "old",
  },
  head_files: {
    "app/views/layouts/custom_styles/_style.html.erb" => "new",
    "app/views/layouts/custom_styles/styles.scss.erb" => "new",
  },
  expect_escalate: true,
  expect_reason: "diff touches app/views/layouts/custom_styles/_style.html.erb but no specs",
)
check(
  "global tailwind.css beside the custom_styles template still escalates on tailwind.css",
  base_files: {
    "spec/models/seller_profile_spec.rb" => "expect(subject.custom_styles).to be_present\n",
    "app/views/layouts/custom_styles/styles.scss.erb" => "old",
    "app/javascript/stylesheets/tailwind.css" => "old",
  },
  head_files: {
    "app/views/layouts/custom_styles/styles.scss.erb" => "new",
    "app/javascript/stylesheets/tailwind.css" => "new",
  },
  expect_escalate: true,
  expect_reason: "diff touches app/javascript/stylesheets/tailwind.css but no specs",
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
