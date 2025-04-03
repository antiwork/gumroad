# frozen_string_literal: true

class ProductIndexingService
  def self.perform(product:, action:, attributes_to_update: [], on_failure: :raise)
    case action
    when "index"
      product.__elasticsearch__.index_document
    when "update"
      return if attributes_to_update.empty?

      attributes = product.build_search_update(attributes_to_update)
      product.__elasticsearch__.update_document_attributes(attributes.as_json)
    end
  rescue
    if on_failure == :async
      SendToElasticsearchWorker.perform_in(5.seconds, product.id, action, attributes_to_update)
      Rails.logger.error("Failed to #{action} product #{product.id} (#{attributes_to_update.join(", ")}), queued job instead")
    else
      raise
    end
  end
end
