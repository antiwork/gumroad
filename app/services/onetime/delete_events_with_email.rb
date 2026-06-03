# frozen_string_literal: true

# Deletes `events` rows that still have a value in the legacy `email` column.
#
# No current code path writes `events.email` — the column is a vestige of an older
# tracking design. The only rows that hold a value are old ones, and that value is
# buyer PII (`GdprBuyerErasureService` looks events up by it). Clearing these rows
# removes the residual PII and lets us drop the column later without a value-bearing
# legacy column getting in the way.
#
# The table is one of the largest in the database, so we delete in primary-key batches
# and pause between batches whenever a replica falls more than 10 seconds behind.
module Onetime
  class DeleteEventsWithEmail
    BATCH_SIZE = 1_000
    MAX_LAG_ALLOWED_SECONDS = 10

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      deleted = 0

      Event.where.not(email: nil).in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch(max_lag_allowed: MAX_LAG_ALLOWED_SECONDS)
        deleted += batch.delete_all
        puts "deleted #{deleted} events so far"
      end

      puts "done: deleted #{deleted} events with email present"
      deleted
    end
  end
end
