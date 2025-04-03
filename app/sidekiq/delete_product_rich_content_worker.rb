# frozen_string_literal: true

class DeleteProductRichContentWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(product_id, variant_id = nil)
    product = Link.find(product_id)

    if variant_id.present?
      variant = BaseVariant.find(variant_id)
      delete_rich_content(product, variant:)
    else
      delete_rich_content(product)
      product.variants.find_each do |product_variant|
        delete_rich_content(product, variant: product_variant)
      end
    end
  end

  private
    def delete_rich_content(product, variant: nil)
      product_or_variant = variant.presence || product

      return unless product_or_variant.alive_rich_contents.exists? && product_or_variant.deleted?

      product_or_variant.alive_rich_contents.find_each(&:mark_deleted!)
    end
end
