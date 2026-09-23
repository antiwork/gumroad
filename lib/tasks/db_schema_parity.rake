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
    # The shell discards this exit status, so this report is the only signal that the live schema is
    # short of what db/schema.rb declares.
    ErrorNotifier.notify(e, exclude_request_context: true, task: "db:schema_parity")
    abort "db:schema_parity failed: #{e.class}: #{e.message}"
  end
end
