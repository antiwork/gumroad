#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/branch-specs' mapping layers: Public/Profile component
# fanout, a per-file config/ exception list, vitest co-location, lib/app
# content-attribution fallback, and help_center view mapping.
#
# Same shape as check_migration_versions_test.rb: throwaway git repos, no
# Rails. The selector runs from the repo root of the throwaway repo, so each
# scenario lays down the spec files its mapping should find.
#
#   ruby spec/bin/branch_specs_test.rb

require "tmpdir"
require "fileutils"
require "open3"

SELECTOR = File.expand_path("../../bin/branch-specs", __dir__)

$failures = []
$count = 0

def build_repo(dir, base_files:, head_files:)
  Dir.chdir(dir) do
    system("git init -q -b main .", exception: true)
    system("git config user.email t@t.t", exception: true)
    system("git config user.name t", exception: true)
    system("git config commit.gpgsign false", exception: true)

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

def check(name, base_files:, head_files:, expect_specs: nil, expect_escalate: false)
  $count += 1
  Dir.mktmpdir do |dir|
    build_repo(dir, base_files:, head_files:)
    stdout, stderr, status = Open3.capture3("ruby", SELECTOR, "--base", "base", chdir: dir)

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

# A genuinely unmapped app file must still escalate (the guard this whole
# selector exists for).
check(
  "unmapped app file still escalates",
  base_files: { "app/javascript/components/Novel/Thing.tsx" => "old" },
  head_files: { "app/javascript/components/Novel/Thing.tsx" => "new" },
  expect_escalate: true,
)

if $failures.empty?
  puts "#{$count} checks passed"
else
  $failures.each { |f| puts "FAIL: #{f}\n\n" }
  abort "#{$failures.size}/#{$count} checks failed"
end
