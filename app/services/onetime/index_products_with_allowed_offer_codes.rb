# frozen_string_literal: true

class Onetime::IndexProductsWithAllowedOfferCodes
  def self.process
    allowed_codes = SearchProducts::ALLOWED_OFFER_CODES
    offer_codes = OfferCode.alive.where(code: allowed_codes)

    indexed_product_ids = Set.new
    batch_index = 0

    offer_codes.find_each do |offer_code|
      offer_code.applicable_products.pluck(:id).each do |product_id|
        next if indexed_product_ids.include?(product_id)

        indexed_product_ids << product_id
        SendToElasticsearchWorker.perform_in(
          (batch_index / 100 * 30).seconds,
          product_id,
          "update",
          ["offer_codes"]
        )
        batch_index += 1
      end
    end

    Rails.logger.info "Enqueued #{indexed_product_ids.size} reindex jobs"
  end
end
