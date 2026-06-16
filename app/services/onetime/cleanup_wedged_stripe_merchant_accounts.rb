# frozen_string_literal: true

# Cleans up half-provisioned Stripe merchant accounts that permanently wedge a
# seller's payout onboarding. See issue #487.
#
# StripeMerchantAccountManager.create_account is non-atomic: between
# Stripe::Account.create (which saves charge_processor_merchant_id) and the line
# that sets charge_processor_alive_at, a non-Stripe interruption (deploy, DB blip,
# timeout) used to escape the rescue — which only caught Stripe::StripeError — and
# leave a MerchantAccount with a merchant id, no charge_processor_alive_at, and no
# charge_processor_deleted_at. The self-serve form guard
# (merchant_accounts.stripe.alive.empty?) then sees that row and never lets the
# seller retry, so payouts skip forever with "the payout bank account was not
# correctly set up".
#
# The forward fix broadens that rescue so new failures clean up after themselves.
# This task remediates the rows stranded before that shipped: for each wedged row
# whose owner has no other alive Stripe account it runs the same cleanup the
# forward fix uses — StripeMerchantAccountManager.cleanup_failed_merchant_account —
# which deletes the orphaned half-provisioned Stripe account and soft-deletes the
# row, so the seller can onboard again from scratch via the normal flow.
#
# It does NOT re-provision accounts or move money. Owners with a stranded balance
# are logged so support can prompt them to re-enter their payout details.
module Onetime
  class CleanupWedgedStripeMerchantAccounts
    BATCH_SIZE = 100

    # Skip rows young enough that they might be a live onboarding still in flight
    # rather than a stranded one.
    MIN_AGE = 7.days

    def self.process(dry_run: true, merchant_account_ids: nil)
      new.process(dry_run:, merchant_account_ids:)
    end

    def process(dry_run: true, merchant_account_ids: nil)
      stats = Hash.new(0)
      ActiveRecord::Base.connection.stick_to_primary! unless dry_run

      candidates(merchant_account_ids).find_in_batches(batch_size: BATCH_SIZE) do |batch|
        ReplicaLagWatcher.watch

        batch.each do |merchant_account|
          stats[:scanned] += 1

          user = merchant_account.user
          if user.nil?
            stats[:skipped_no_user] += 1
            next
          end

          if user.merchant_accounts.alive.stripe.charge_processor_alive.exists?
            stats[:skipped_has_alive_account] += 1
            next
          end

          if user.unpaid_balance_cents > 0
            stats[:wedged_with_balance] += 1
            puts "balance: user #{user.id} merchant_account #{merchant_account.id} balance #{user.unpaid_balance_cents}c"
          end

          if dry_run
            stats[:would_clean] += 1
            puts "DRY-RUN clean merchant_account #{merchant_account.id} user #{user.id}"
            next
          end

          merchant_account.reload
          unless merchant_account.alive? && merchant_account.charge_processor_alive_at.nil?
            stats[:skipped_no_longer_wedged] += 1
            next
          end

          StripeMerchantAccountManager.cleanup_failed_merchant_account(merchant_account)
          stats[:cleaned] += 1
          puts "cleaned merchant_account #{merchant_account.id} user #{user.id}"
        end
      end

      puts "done: #{stats.to_h}"
      stats.to_h
    end

    private
      def candidates(merchant_account_ids)
        scope = MerchantAccount
                  .where(charge_processor_id: StripeChargeProcessor.charge_processor_id)
                  .where(charge_processor_alive_at: nil, charge_processor_deleted_at: nil, deleted_at: nil)
                  .where.not(charge_processor_merchant_id: nil)
                  .where("created_at < ?", MIN_AGE.ago)
        scope = scope.where(id: merchant_account_ids) if merchant_account_ids.present?
        scope
      end
  end
end
