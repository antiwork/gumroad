# frozen_string_literal: true

# Migrates sellers whose `UserComplianceInfo.country` is "Puerto Rico" to
# `country: "United States"` with `state: "PR"`. The codebase now treats PR as a US state
# end-to-end (no more `TERRITORY_TO_PARENT_COUNTRY` indirection), so existing records need
# to be brought into line.
#
# Why only Puerto Rico (and not the other US outlying areas):
# Stripe Connect explicitly rejects every other US outlying area (American Samoa, Guam,
# Northern Mariana Islands, Virgin Islands, Minor Outlying Islands) with:
#   "Address is in an unsupported state. Stripe currently does not support US insular
#    areas and freely associated states."
# Verified against real Stripe test API on 2026-05-29. PR is the only US outlying area
# that Stripe accepts under `country: "US"`, so it is the only one we can migrate.
#
# UCI is event-sourced via the `Immutable` concern: each change is a new row, and
# `alive_user_compliance_info` returns the latest non-deleted. We use `dup_and_save!`
# to clone the alive UCI, soft-delete the original, and save the new one atomically.
#
# `skip_stripe_job_on_create = true` is set on the dup so `HandleNewUserComplianceInfoWorker`
# does not fire ~4.5k times; the small Stripe-connected cohort is re-synced separately.
module Onetime
  class MigratePuertoRicoToUsState
    BATCH_SIZE = 200

    TERRITORY_NAME_TO_STATE_CODE = {
      Compliance::Countries::PRI.common_name => "PR",
    }.freeze

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      TERRITORY_NAME_TO_STATE_CODE.each do |country_name, state_code|
        puts "=== Migrating #{country_name} sellers → United States/#{state_code} ==="
        migrated = 0
        skipped = 0

        # `company_hash` sends `country: legal_entity_country_code` to Stripe, which falls back
        # to `business_country_code` for business sellers — so any UCI with `business_country`
        # set to the territory will hit a Stripe rejection on next sync even if its personal
        # `country` is something else. Match either field so no PR-tainted UCI is left behind.
        UserComplianceInfo
          .where("country = ? OR business_country = ?", country_name, country_name)
          .alive
          .in_batches(of: batch_size) do |batch|
            ReplicaLagWatcher.watch
            batch.each do |uci|
              if migrate_uci(uci, country_name, state_code)
                migrated += 1
              else
                skipped += 1
              end
            end
          end

        puts "  done: migrated=#{migrated} skipped=#{skipped}"
      end
    end

    private
      def migrate_uci(uci, country_name, state_code)
        # Idempotency: only migrate if this is still the alive UCI for the user.
        return false unless uci.user&.alive_user_compliance_info&.id == uci.id

        uci.dup_and_save! do |new_uci|
          if uci.country == country_name
            new_uci.country = Compliance::Countries::USA.common_name
            new_uci.state   = state_code
          end
          if uci.business_country == country_name
            new_uci.business_country = Compliance::Countries::USA.common_name
            new_uci.business_state   = state_code
          end
          new_uci.skip_stripe_job_on_create = true
        end

        puts "  migrated user_id=#{uci.user_id}"
        true
      rescue => e
        puts "  SKIPPED user_id=#{uci.user_id}: #{e.class}: #{e.message}"
        false
      end
  end
end
