# frozen_string_literal: true

# Sends one Purchase event to the seller's Meta dataset. Every gate is re-checked here, at send
# time: the checkout request that saved the context only knows the state it saw.
class SendMetaConversionEventJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  class SendFailed < StandardError; end

  def perform(purchase_id)
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
      setting.update!(token_rejected_at: Time.current)
    end

    log(purchase, outcome: result.outcome.to_s, reason: result.reason, result:)

    raise SendFailed, "Meta rejected the request with reason #{result.reason}" if result.outcome == :retry
  end

  private
    def log(purchase, outcome:, reason: nil, result: nil)
      Rails.logger.info(
        "MetaConversions outcome=#{outcome} reason=#{reason} purchase_id=#{purchase.id} " \
        "seller_id=#{purchase.seller_id} http_status=#{result&.http_status} " \
        "fb_error_code=#{result&.error_code} fbtrace_id=#{result&.trace_id}"
      )
    end
end
