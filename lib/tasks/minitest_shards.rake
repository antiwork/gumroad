# frozen_string_literal: true

require "shellwords"
require "yaml"

module MinitestShardTasks
  module_function

  def run(suite:, default_paths:, task_name:, command: nil)
    files = selected_files(suite:, default_paths:, task_name:)
    abort "No test files found for #{task_name}" if files.empty?

    if command
      sh Shellwords.join([command, *files])
    else
      sh Shellwords.join(["bundle", "exec", "ruby", "-Itest", *files])
    end
  end

  def selected_files(suite:, default_paths:, task_name:)
    args = task_args(task_name)
    shard = shard_arg(args)
    paths = args.reject.with_index do |arg, index|
      arg == "--shard" || (index.positive? && args[index - 1] == "--shard") || arg.start_with?("-")
    end

    files = expand(paths.presence || default_paths)
    return files unless shard

    shard_index, shard_total = shard.split("/", 2).map(&:to_i)
    abort "Invalid --shard value: #{shard}" unless shard_index.positive? && shard_total.positive?

    manifest = YAML.load_file(Rails.root.join("test/.shards.yml"))
    configured_total = manifest.fetch(suite).fetch("total")
    abort "Shard total mismatch for #{suite}: expected #{configured_total}, got #{shard_total}" unless configured_total == shard_total

    assignments = manifest.fetch(suite).fetch("files")
    files.select { |file| assignments.fetch(file, nil) == shard_index }
  end

  def task_args(task_name)
    index = ARGV.index(task_name)
    return [] unless index

    args = ARGV[(index + 1)..] || []
    args = args.drop(1) if args.first == "--"
    args
  end

  def shard_arg(args)
    index = args.index("--shard")
    args[index + 1] if index
  end

  def expand(paths)
    Array(paths).flat_map do |path|
      if File.directory?(path)
        Dir.glob("#{path}/**/*_test.rb")
      elsif File.file?(path)
        path
      end
    end.compact.uniq.sort
  end
end

namespace :test do
  Rake::Task["test:integration"].clear if Rake::Task.task_defined?("test:integration")
  Rake::Task["test:system"].clear if Rake::Task.task_defined?("test:system")

  desc "Run controller, integration, and routing tests"
  task :integration do
    MinitestShardTasks.run(
      suite: "integration",
      default_paths: %w[test/controllers test/integration test/routing],
      task_name: "test:integration",
    )
  end

  desc "Run Playwright system tests"
  task :system do
    MinitestShardTasks.run(
      suite: "system",
      default_paths: %w[test/system],
      task_name: "test:system",
      command: "bin/test-system",
    )
  end
end

ARGV.each do |arg|
  next if Rake::Task.task_defined?(arg)
  task arg.to_sym do
  end
end
