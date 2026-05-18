# frozen_string_literal: true

module Onetime
  class BackfillStripeDisabledReason
    BATCH_SIZE = 500

    def self.process(batch_size: BATCH_SIZE)
      new.process(batch_size:)
    end

    def process(batch_size: BATCH_SIZE)
      scope = MerchantAccount.stripe
        .charge_processor_alive
        .where.not(charge_processor_merchant_id: nil)

      scope.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        batch.each { |merchant_account| sync_disabled_reason(merchant_account) }
      end
    end

    private
      def sync_disabled_reason(merchant_account)
        return if merchant_account.is_a_stripe_connect_account?

        stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
        disabled_reason = stripe_account["requirements"]&.dig("disabled_reason")
        return if merchant_account.stripe_disabled_reason == disabled_reason

        merchant_account.update!(stripe_disabled_reason: disabled_reason)
        puts "Updated MerchantAccount #{merchant_account.id} → #{disabled_reason.inspect}"
      rescue Stripe::StripeError => e
        puts "Skipped MerchantAccount #{merchant_account.id}: #{e.class} #{e.message}"
      end
  end
end
