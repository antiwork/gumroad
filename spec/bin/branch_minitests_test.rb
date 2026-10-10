#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/branch-minitests. Each check builds a throwaway git repo with a
# few test files, changes some paths on a branch, and runs the selector there.
#
#   ruby spec/bin/branch_minitests_test.rb

require "tmpdir"
require "fileutils"
require "open3"

SELECTOR = File.expand_path("../../bin/branch-minitests", __dir__)

TEST_FILES = {
  "test/models/purchase_test.rb" => "class PurchaseTest; def test_a = Purchase.new; end\n",
  "test/controllers/links_controller_test.rb" => "class LinksControllerTest < ActionController::TestCase; end\n",
  "test/models/subscription_test.rb" => "class SubscriptionTest; def test_a = Subscription.new; end\n",
  "test/test_helper.rb" => "# helper\n",
  "test/services/price_checker_service_test.rb" => "class PriceCheckerServiceTest; def test_a = PriceCheckerService.new; end\n",
  "app/services/price_checker_service.rb" => "class PriceCheckerService\n  def call = :checked\nend\n",
}.freeze

$failures = []
$count = 0

def run_selector(changes, base_ref: nil, renames: {})
  Dir.mktmpdir do |dir|
    Dir.chdir(dir) do
      system("git init -q -b main . && git config user.email t@example.com && git config user.name t && git config commit.gpgsign false", exception: true)
      TEST_FILES.each { |path, content| FileUtils.mkdir_p(File.dirname(path)); File.write(path, content) }
      system("git add -A && git commit -q -m base", exception: true)
      base = `git rev-parse HEAD`.strip
      renames.each { |from, to| FileUtils.mkdir_p(File.dirname(to)); system("git", "mv", from, to, exception: true) }
      changes.each { |path, content| FileUtils.mkdir_p(File.dirname(path)); File.write(path, content) }
      system("git add -A && git commit -q -m change --allow-empty", exception: true)
      Open3.capture3("ruby", SELECTOR, base_ref || base)
    end
  end
end

def check(name, changes, expect: nil, all: false, fails: false, base_ref: nil, renames: {})
  $count += 1
  stdout, stderr, status = run_selector(changes, base_ref:, renames:)
  got = stdout.split("\n").sort
  ok =
    if fails then !status.success? && stderr.include?("failed")
    elsif all then status.success? && got == ["ALL"]
    else status.success? && got == expect.sort
    end
  $failures << "#{name}: got #{got.inspect} (exit #{status.exitstatus})\n#{stderr}" unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
end

check("a JavaScript change selects nothing", { "app/javascript/components/Foo.tsx" => "x" }, expect: [])
check("a spec change selects nothing", { "spec/models/purchase_spec.rb" => "x" }, expect: [])
check("a model change selects the tests that name its class", { "app/models/purchase.rb" => "x" }, expect: ["test/models/purchase_test.rb"])
check("a nested file selects the tests that name a module on its path", { "app/models/purchase/refund_logic.rb" => "x" }, expect: ["test/models/purchase_test.rb"])
check("a view selects the tests that name its controller", { "app/views/links/edit.html.erb" => "x" }, expect: ["test/controllers/links_controller_test.rb"])
check("a changed test file runs", { "test/models/subscription_test.rb" => "class SubscriptionTest; end\n" }, expect: ["test/models/subscription_test.rb"])
check("a lib file selects the tests that name it", { "lib/subscription.rb" => "x" }, expect: ["test/models/subscription_test.rb"])
check("a data file under app/ selects the tests that name a module on its path", { "app/models/subscription/plans.yml" => "x" }, expect: ["test/models/subscription_test.rb"])
check("a Buildkite change selects nothing", { ".buildkite/pipeline.yml" => "x" }, expect: [])
check("a renamed file still selects the tests that name its old class", {}, renames: { "app/services/price_checker_service.rb" => "app/services/product_price_checker.rb" }, expect: ["test/services/price_checker_service_test.rb"])
check("the test helper runs everything", { "test/test_helper.rb" => "# changed\n" }, all: true)
check("a spec/support helper runs everything", { "spec/support/stripe_payment_method_helper.rb" => "x" }, all: true)
check("a config change runs everything", { "config/initializers/foo.rb" => "x" }, all: true)
check("a Gemfile.lock change runs everything", { "Gemfile.lock" => "x" }, all: true)
check("a layout runs everything", { "app/views/layouts/application.html.erb" => "x" }, all: true)
check("a path no rule covers runs everything", { "Procfile" => "x" }, all: true)
check("a git failure stops the selector", { "app/models/purchase.rb" => "x" }, fails: true, base_ref: "0" * 40)

if $failures.empty?
  puts "#{$count} checks passed"
else
  $failures.each { |f| puts "FAIL: #{f}\n\n" }
  abort "#{$failures.size}/#{$count} checks failed"
end
