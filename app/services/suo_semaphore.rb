# frozen_string_literal: true

class SuoSemaphore
  class << self
    def recurring_charge(subscription_id)
      Suo::Client::Redis.new("locks:recurring_charge:#{subscription_id}", default_options)
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
