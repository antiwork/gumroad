# frozen_string_literal: true

require_relative "../db_schema_parity"

namespace :db do
  desc "Report schema db/schema.rb declares that the live database does not have"
  task schema_parity: :environment do
    missing = DbSchemaParity.from_live_connection.missing

    if missing.empty?
      puts "db:schema_parity: the live schema has everything db/schema.rb declares"
      next
    end

    missing.each { |row| puts "db:schema_parity: MISSING #{row}" }
    raise DbSchemaParity::DriftError, "#{missing.size} schema object(s) declared in db/schema.rb are missing from the live database: #{missing.join('; ')}"
  rescue StandardError => e
    # Like taxonomy:seed, the deploy runs this non-fatally so it cannot hold the migration lock, so
    # the shell discards the exit status — this report is the only thing that tells anyone the live
    # schema is short of what schema.rb declares, which no later deploy will repair.
    ErrorNotifier.notify(e, exclude_request_context: true, task: "db:schema_parity")
    abort "db:schema_parity failed: #{e.class}: #{e.message}"
  end
end
