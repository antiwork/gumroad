# frozen_string_literal: true

class DeleteProductFilesArchivesWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(product_id = nil, variant_id = nil)
    return if product_id.nil? && variant_id.nil?

    variant = BaseVariant.find(variant_id) if variant_id.present?
    product = product_id.present? ? Link.find(product_id) : Link.find(variant.variant_category.link_id)

    if variant_id.present?
      return unless variant.deleted?

      variant.product_files_archives.alive.each(&:mark_deleted!)
    else
      return unless product.deleted?

      product.product_files_archives.alive.each(&:mark_deleted!)
      product.alive_variants.each { _1.product_files_archives.alive.each(&:mark_deleted!) }
    end
  end
end
