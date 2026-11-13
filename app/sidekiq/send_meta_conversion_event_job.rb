# frozen_string_literal: true

# Sends one Purchase event to the seller's Meta dataset. Every gate is re-checked here, at send
# time: the checkout request that saved the context only knows the state it saw.
class SendMetaConversionEventJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  class SendFailed < StandardError; end

  def perform(purchase_id)
    # The purchase committed moments ago in the checkout request, and workers read a replica:
    # both the row and the send-time settings have to come from the primary.
    ApplicationRecord.connected_to(role: :writing) { send_event(purchase_id) }
  end

  private
    def send_event(purchase_id)
      purchase = Purchase.find_by(id: purchase_id)
      return if purchase.nil?

      skip_reason = MetaConversions::Eligibility.seller_skip_reason(purchase.seller)
      return log(purchase, outcome: "skipped", reason: skip_reason) if skip_reason

      context = MetaConversions::PurchaseContext.fetch(purchase.id)
      skip_reason = MetaConversions::Eligibility.purchase_skip_reason(purchase, context)
      return log(purchase, outcome: "skipped", reason: skip_reason) if skip_reason

      setting = purchase.seller.meta_conversions_setting
      result = MetaConversions::Sender.new(purchase, context:, setting:).perform

      if result.outcome == :rejected && result.token_rejected
        # Only the token this request sent: a seller who replaced it while the request was in
        # flight must not have the replacement marked bad, which would stop every later send.
        # One conditional UPDATE: a read-then-write would leave a window for the swap.
        MetaConversionsSetting.where(id: setting.id, access_token: setting.access_token)
                              .update_all(token_rejected_at: Time.current, updated_at: Time.current)
      end

      log(purchase, outcome: result.outcome.to_s, reason: result.reason, result:)

      raise SendFailed, "Meta rejected the request with reason #{result.reason}" if result.outcome == :retry
    end

    def log(purchase, outcome:, reason: nil, result: nil)
      Rails.logger.info(
        "MetaConversions outcome=#{outcome} reason=#{reason} purchase_id=#{purchase.id} " \
        "seller_id=#{purchase.seller_id} http_status=#{result&.http_status} " \
        "fb_error_code=#{result&.error_code} fbtrace_id=#{result&.trace_id}"
      )
    end
end
