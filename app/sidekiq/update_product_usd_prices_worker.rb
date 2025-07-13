# frozen_string_literal: true

class UpdateProductUsdPricesWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform
    Rails.logger.info("Starting USD price update for products...")

    batch_size = 1000
    processed = 0

    Product.find_in_batches(batch_size: batch_size) do |batch|
      batch.each do |product|
        begin
          product.__elasticsearch__.index_document
          processed += 1
        rescue => e
          Rails.logger.error("Failed to update USD prices for product #{product.id}: #{e.message}")
        end
      end

      Rails.logger.info("Processed #{processed} products...")
    end

    Rails.logger.info("USD price update complete! Processed #{processed} products.")
  end
end
