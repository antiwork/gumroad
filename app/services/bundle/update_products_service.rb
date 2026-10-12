# frozen_string_literal: true

class Bundle::UpdateProductsService
  def initialize(bundle:, products:)
    @bundle = bundle
    @products = products
  end

  def perform
    caller_flags_change = @bundle.changes["flags"]&.map(&:to_i)

    Link.transaction do
      lock_seller_then_bundle(caller_flags_change)

      products_to_process = @products.dup
      bundle_products = @bundle.bundle_products.includes(:product)

      bundle_products.each do |bundle_product|
        new_bundle_product = products_to_process.find { _1[:product_id] == bundle_product.product.external_id }
        if new_bundle_product.present?
          bundle_product.update!(
            variant: BaseVariant.find_by_external_id(new_bundle_product[:variant_id]),
            quantity: new_bundle_product[:quantity],
            deleted_at: nil,
            position: new_bundle_product[:position]
          )
          products_to_process.delete(new_bundle_product)
          update_has_outdated_purchases
        else
          bundle_product.mark_deleted(validate: false)
        end
      end

      update_has_outdated_purchases if products_to_process.present?

      products_to_process.each do |new_bundle_product|
        product = Link.find_by_external_id!(new_bundle_product[:product_id])
        variant = BaseVariant.find_by_external_id(new_bundle_product[:variant_id])

        @bundle.bundle_products.create!(
          product:,
          variant:,
          quantity: new_bundle_product[:quantity],
          position: new_bundle_product[:position]
        )
      end

      @bundle.save!
      @bundle
    end
  end

  private
    # Lock seller before bundle to match save/restore and avoid overlapping-conversion deadlocks.
    # Re-read shared flags under lock, then merge caller bits without reloading other dirty attributes.
    def lock_seller_then_bundle(caller_flags_change)
      User.where(id: @bundle.user_id).lock.pick(:id)
      locked_flags = Link.where(id: @bundle.id).lock.pick(:flags)
      return if locked_flags.nil?

      if caller_flags_change
        previous_flags, requested_flags = caller_flags_change
        changed_bits = previous_flags ^ requested_flags
        @bundle.flags = (locked_flags.to_i & ~changed_bits) | (requested_flags & changed_bits)
      else
        @bundle.flags = locked_flags.to_i
      end
    end

    def update_has_outdated_purchases
      return if @bundle.has_outdated_purchases?

      @bundle.has_outdated_purchases = true if @bundle.successful_sales_count > 0
    end
end
