# frozen_string_literal: true

class ScheduleAbandonedCartEmailsJob
  include Sidekiq::Job

  BATCH_SIZE = 500

  sidekiq_options queue: :low, retry: 5, lock: :until_executed

  def perform
    # cart_product_ids_with_cart_ids is a hash of { product_id => { cart_id => [variant_ids] } }
    cart_product_ids_with_cart_ids = {}

    days_to_process = (Cart::ABANDONED_IF_UPDATED_AFTER_AGO.to_i / 1.day.to_i)
    (1..days_to_process).each do |day|
      day_start = day.days.ago.beginning_of_day
      day_end = day == 1 ? Cart::ABANDONED_IF_UPDATED_BEFORE_AGO.ago : (day - 1).days.ago.beginning_of_day

      start_time = Time.current
      cart_ids = Cart.abandoned(updated_at: day_start..day_end).pluck(:id)
      cart_ids.each_slice(BATCH_SIZE) do |batch_ids|
        Cart.includes(:alive_cart_products).where(id: batch_ids).each do |cart|
          next if cart.user_id.blank? && cart.email.blank?

          cart.alive_cart_products.each do |cart_product|
            product_id = cart_product.product_id
            variant_id = cart_product.option_id
            cart_product_ids_with_cart_ids[product_id] ||= {}
            cart_product_ids_with_cart_ids[product_id][cart.id] ||= []
            cart_product_ids_with_cart_ids[product_id][cart.id] << variant_id if variant_id.present?
          end
        end
      end
      Rails.logger.info "Fetched #{cart_ids.count} carts for #{day_start} to #{day_end} in #{(Time.current - start_time).round(2)} seconds"
    end

    # cart_ids_with_matched_workflow_ids_and_product_ids is a hash of { cart_id => { workflow_id => [product_ids] } }
    cart_ids_with_matched_workflow_ids_and_product_ids = {}

    start_time = Time.current
    Workflow.distinct.alive.abandoned_cart_type.published.joins(seller: :links).merge(User.alive.not_suspended).merge(Link.visible_and_not_archived).includes(:seller).find_each do |workflow|
      next unless workflow.seller&.eligible_for_abandoned_cart_workflows?

      workflow.abandoned_cart_products(only_product_and_variant_ids: true).each do |product_id, variant_ids|
        next unless cart_product_ids_with_cart_ids.key?(product_id)

        cart_product_ids_with_cart_ids[product_id].each do |cart_id, cart_variant_ids|
          has_matching_variants = variant_ids.empty? || (variant_ids & cart_variant_ids).any?
          next unless has_matching_variants

          cart_ids_with_matched_workflow_ids_and_product_ids[cart_id] ||= {}
          cart_ids_with_matched_workflow_ids_and_product_ids[cart_id][workflow.id] ||= []
          cart_ids_with_matched_workflow_ids_and_product_ids[cart_id][workflow.id] << product_id
        end
      end
    end

    Rails.logger.info "Fetched #{cart_ids_with_matched_workflow_ids_and_product_ids.count} cart ids with matched workflow ids and product ids in #{(Time.current - start_time).round(2)} seconds"

    cart_ids_with_matched_workflow_ids_and_product_ids.each do |cart_id, workflow_ids_with_product_ids|
      CustomerMailer.abandoned_cart(cart_id, workflow_ids_with_product_ids.stringify_keys).deliver_later(queue: "low")
    end
  end
end
