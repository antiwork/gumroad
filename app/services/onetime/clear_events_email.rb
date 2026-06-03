# frozen_string_literal: true

# Clears the legacy `email` column on `events` rows that still carry a value.
#
# The rows that hold an email are recurring-subscription-charge `purchase` events:
# `Subscription#create_purchase_event` builds each recurring charge's event by
# `dup`-ing the subscription's original purchase event, and for subscriptions whose
# original event predates the change that stopped populating `events.email`, that dup
# copied an old buyer email forward onto every new charge (fixed in #5383). Those rows
# are live `purchase` events — read by refund/chargeback/dispute handling, subscription
# charge tracking, and sales analytics — so we must not delete them. We only null out
# the residual PII, matching what `GdprBuyerErasureService#anonymize_events!` does (it
# is the sole reader of the column). This lets us drop the column later without a
# value-bearing legacy column getting in the way.
#
# The table is one of the largest in the database, so we update in primary-key batches
# and pause between batches whenever a replica falls more than 10 seconds behind.
module Onetime
  class ClearEventsEmail
    BATCH_SIZE = 1_000
    MAX_LAG_ALLOWED_SECONDS = 10

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      cleared = 0

      Event.where.not(email: nil).in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch(max_lag_allowed: MAX_LAG_ALLOWED_SECONDS)
        cleared += batch.update_all(email: nil)
        puts "cleared #{cleared} events so far"
      end

      puts "done: cleared email on #{cleared} events"
      cleared
    end
  end
end
