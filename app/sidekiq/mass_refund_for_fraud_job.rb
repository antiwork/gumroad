# frozen_string_literal: true

class MassRefundForFraudJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform(product_id, external_ids, admin_user_id)
    results = { success: 0, failed: 0, errors: {} }

    external_ids.each do |external_id|
      purchase = Purchase.find_by_external_id(external_id)
      unless purchase && purchase.link_id == product_id
        results[:failed] += 1
        results[:errors][external_id] = "Purchase not found"
        next
      end

      begin
        purchase.refund_for_fraud_and_block_buyer!(admin_user_id)
        results[:success] += 1
      rescue StandardError => e
        results[:failed] += 1
        results[:errors][external_id] = e.message
        Rails.logger.error("Mass fraud refund failed for purchase #{external_id}: #{e.message}")
        Bugsnag.notify(e) do |event|
          event.add_metadata(:mass_refund, {
                               product_id: product_id,
                               purchase_external_id: external_id,
                               admin_user_id: admin_user_id
                             })
        end
      end
    end

    Rails.logger.info("Mass fraud refund completed for product #{product_id}: #{results[:success]} succeeded, #{results[:failed]} failed")
  end
end
