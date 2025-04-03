# typed: strict
# frozen_string_literal: true

desc "Clear the Rails.cache"
task clear_cache: :environment do
  Rails.cache.clear
  puts "Cache is cleared"
end

task "db:migrate" => :clear_cache
