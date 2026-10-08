#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/vitest-ci's choice of test files. Runs from the repository root
# against the real app/javascript tree, so a selection depends on real imports.
#
#   ruby spec/bin/vitest_ci_test.rb

require "open3"

SCRIPT = File.expand_path("../../bin/vitest-ci", __dir__)
Dir.chdir(File.expand_path("../..", __dir__))

$failures = []
$count = 0

# Records are [status, path, ...], sent as `git diff --name-status -z` output.
def plan(*records)
  input = records.map { |record| record.join("\0") + "\0" }.join
  out, status = Open3.capture2("ruby", SCRIPT, "--plan", stdin_data: input)
  raise "bin/vitest-ci --plan failed" unless status.success?
  mode, *rest = out.split("\n")
  [mode, rest]
end

def check(name)
  $count += 1
  ok = yield
  $failures << name unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
end

FILE_READING_TEST = "app/javascript/components/gap_cursor_styles.test.ts"

mode, tests = plan(["M", "app/javascript/widget/utils.ts"])
check("a changed source file selects the test that imports it") { mode == "tests" && tests.include?("app/javascript/widget/utils.test.ts") }
check("a changed source file does not select unrelated tests") { !tests.include?("app/javascript/data/customer_surcharge.test.ts") }

mode, tests = plan(["M", "app/javascript/utils/currency.ts"])
check("a type-only import counts: currency.ts selects customer_surcharge.test.ts") { mode == "tests" && tests.include?("app/javascript/data/customer_surcharge.test.ts") }

mode, tests = plan(["M", "app/javascript/data/customer_surcharge.test.ts"])
check("a changed test file selects itself") { mode == "tests" && tests.include?("app/javascript/data/customer_surcharge.test.ts") }

mode, tests = plan(["M", "app/javascript/stylesheets/tailwind.css"])
check("tests that read repository files always run") { mode == "tests" && tests.include?(FILE_READING_TEST) }

mode, tests = plan(["M", "app/models/user.rb"])
check("a Ruby-only change runs only the file-reading tests") { mode == "tests" && tests.include?(FILE_READING_TEST) && !tests.include?("app/javascript/widget/utils.test.ts") }

mode, tests = plan(["M", "app/javascript/pages/Checkout/Show.tsx"])
check("an import with a Vite query (?raw) counts") { mode == "tests" && tests.include?("app/javascript/pages/Checkout/cartItemUidMapping.test.ts") }

mode, tests = plan(["D", "app/javascript/stylesheets/tailwind.css"])
check("a deleted file that a test reads runs the file-reading tests") { mode == "tests" && tests.include?(FILE_READING_TEST) }

mode, tests = plan(["D", "spec/fixtures/accent_contrast_pairs.json"])
check("a deleted fixture still selects the test that imported it") { mode == "tests" && tests.include?("app/javascript/utils/color.test.ts") }

mode, tests = plan(["R100", "spec/fixtures/accent_contrast_pairs.json", "spec/fixtures/renamed_pairs.json"])
check("a renamed fixture still selects the test that imported it") { mode == "tests" && tests.include?("app/javascript/utils/color.test.ts") }

THUMBNAIL = "app/javascript/components/Product/Thumbnail.test.tsx"

mode, tests = plan(["M", "public/images/native_types/thumbnails/audiobook.png"])
check("an image an import.meta.glob matches selects the test of its importer") { mode == "tests" && tests.include?(THUMBNAIL) }

mode, tests = plan(["A", "public/images/native_types/thumbnails/new_type.png"])
check("an added file matching an import.meta.glob selects the test of its importer") { mode == "tests" && tests.include?(THUMBNAIL) }

mode, tests = plan(["M", "public/images/discover/art.png"])
check("a file outside an import.meta.glob does not select its importer's test") { mode == "tests" && !tests.include?(THUMBNAIL) && tests.include?("app/javascript/utils/discover.test.ts") }

# The glob matcher itself, on synthetic sources, loaded into its own module so the
# script's `plan` does not replace this file's.
GLOBS = Module.new
GLOBS.module_eval(File.read(SCRIPT).split(/^def git\b/).first)
GLOB_HELPERS = Object.new.extend(GLOBS)

def glob_matches?(source, path, from: "app/javascript/a.tsx")
  GLOB_HELPERS.glob_matchers(from, source).any? { |matcher| matcher.call(path) }
end

check("a glob array with a negated pattern excludes the negated files") do
  source = %q{import.meta.glob(["./pages/**/*.tsx", "!./pages/**/*.test.tsx"])}
  glob_matches?(source, "app/javascript/pages/x/Y.tsx") && !glob_matches?(source, "app/javascript/pages/x/Y.test.tsx")
end
check("a negated pattern applies only to its own import.meta.glob call") do
  source = %q{import.meta.glob("./a/*.ts"); import.meta.glob(["./b/*.ts", "!./a/*.ts"])}
  glob_matches?(source, "app/javascript/a/x.ts")
end
check("a glob with a generic, a [id] file name and options still parses") do
  source = %q{import.meta.glob<Record<string, string>>("./p/[id].tsx", { eager: true })}
  glob_matches?(source, "app/javascript/p/[id].tsx")
end
check("a trailing ** and {a,b} alternation match nested files") do
  glob_matches?(%q{import.meta.glob("$assets/images/**")}, "public/images/a/b/c.png", from: "app/javascript/a.tsx") &&
    glob_matches?(%q{import.meta.glob("./i/*.{png,svg}")}, "app/javascript/i/x.svg") &&
    !glob_matches?(%q{import.meta.glob("./i/*.{png,svg}")}, "app/javascript/i/x.jpg")
end

check("a [!a] class negates, and an unreadable pattern (extglob, base option) matches every path") do
  !glob_matches?(%q{import.meta.glob("./[!a]/x.ts")}, "app/javascript/a/x.ts") && glob_matches?(%q{import.meta.glob("./[!a]/x.ts")}, "app/javascript/b/x.ts") &&
    glob_matches?(%q{import.meta.glob("./x/@(a|b).ts")}, "app/javascript/other/z.ts") &&
    glob_matches?(%q{import.meta.glob("./x/*.ts", { base: "/foo" })}, "app/javascript/other/z.ts")
end
check("an apostrophe in a comment or an escaped quote cannot leak a later call's patterns") do
  source = %q{import.meta.glob("./a/\"*.ts", {/* don't */ eager: true}); import.meta.glob(["./b/*.ts", "!./a/*.ts"])}
  glob_matches?(source, "app/javascript/b/x.ts")
end

check("an invalid bracket class or an escaped pattern matches every path instead of failing") do
  glob_matches?(%q{import.meta.glob("./a[]/*.ts")}, "app/javascript/other/z.ts") &&
    glob_matches?(%q{import.meta.glob("./p/\\[id\\].tsx")}, "app/javascript/other/z.ts")
end

mode, = plan
check("a branch with no changes runs nothing") { mode == "none" }

mode, tests = plan(["R100", "app/models/a.rb", "app/models/b.rb"], ["M", "app/javascript/widget/utils.ts"])
check("-z records with a rename parse into the right paths") { mode == "tests" && tests.include?("app/javascript/widget/utils.test.ts") }

[
  "package.json", "package-lock.json", ".npmrc", "patches/@typia+unplugin+12.1.1.patch",
  "vitest.config.ts", "vite.config.ts", "vite.config.widget.ts", "tsconfig.json",
  "scripts/__fixtures__/typia_shared_program/index.ts", "app/javascript/types/global.d.ts",
  "bin/vitest-ci", ".github/workflows/tests.yml",
].each do |path|
  mode, = plan(["M", path])
  check("#{path} runs the whole suite") { mode == "full" }
end

mode, = plan(["D", "app/javascript/utils/old.ts"])
check("a deleted TS file runs the whole suite") { mode == "full" }
mode, = plan(["R090", "app/javascript/a.tsx", "app/javascript/b.tsx"])
check("a renamed TSX file runs the whole suite") { mode == "full" }

puts
if $failures.empty?
  puts "#{$count} checks passed"
else
  puts "#{$failures.size} of #{$count} checks failed"
  exit 1
end
