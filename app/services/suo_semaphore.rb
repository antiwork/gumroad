# frozen_string_literal: true

class SuoSemaphore
  CUSTOM_DOMAIN_CERTIFICATE_LOCK_EXPIRATION = 1.hour

  class << self
    def recurring_charge(subscription_id)
      Suo::Client::Redis.new("locks:recurring_charge:#{subscription_id}", default_options)
    end

    def custom_domain_certificate(custom_domain_id)
      options = default_options.merge(stale_lock_expiration: CUSTOM_DOMAIN_CERTIFICATE_LOCK_EXPIRATION.to_i)
      Suo::Client::Redis.new("locks:custom_domain:#{custom_domain_id}:certificate", options)
    end

    def product_inventory(product_id, extra_options = {})
      options = default_options.merge(stale_lock_expiration: 60).merge(extra_options)
      Suo::Client::Redis.new("locks:product:#{product_id}:inventory", options)
    end

    private
      def default_options
        { client: $redis }
      end
  end
end
