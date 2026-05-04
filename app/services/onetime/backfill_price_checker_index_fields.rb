# frozen_string_literal: true

module Onetime
  class BackfillPriceCheckerIndexFields
    BATCH_SIZE = 1_000
    ATTRIBUTES_TO_UPDATE = %w[price_currency_type customizable_price native_type].freeze

    def self.process(start_id: 0, end_id: nil, batch_size: BATCH_SIZE)
      new.process(start_id:, end_id:, batch_size:)
    end

    def process(start_id: 0, end_id: nil, batch_size: BATCH_SIZE)
      scope = Link.where("id >= ?", start_id)
      scope = scope.where("id <= ?", end_id) if end_id

      scope.in_batches(of: batch_size) do |batch|
        ReplicaLagWatcher.watch
        batch.each do |product|
          ProductIndexingService.perform(
            product:,
            action: "update",
            attributes_to_update: ATTRIBUTES_TO_UPDATE,
            on_failure: :async
          )
        end
        sleep 0.1
      end
    end
  end
end
