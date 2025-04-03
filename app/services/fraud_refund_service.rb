# frozen_string_literal: true

# To run:
# FraudRefundService.new(permalink: "xxx", start_date: 7.days.ago, end_date: Time.current, refunding_user_id: 2_241_816).process
class FraudRefundService
  attr_reader :product, :start_date, :end_date, :refunding_user_id, :dry_run

  def initialize(permalink:, start_date:, end_date:, refunding_user_id:, dry_run: true)
    @product = Link.find_by_unique_permalink(permalink)
    @start_date = start_date
    @end_date = end_date
    @refunding_user_id = refunding_user_id
    @dry_run = dry_run
  end

  def process
    purchases_to_refund = product.sales.joins(:url_redirect)
                                 .where(url_redirects: { uses: 0 })
                                 .not_chargedback_or_chargedback_reversed
                                 .paid
                                 .where(created_at: start_date..end_date)

    return if dry_run

    purchases_to_refund.find_each do |purchase|
      RefundPurchaseWorker.perform_async(purchase.id, refunding_user_id, Refund::FRAUD)
    end

    purchases_to_refund.count
  end
end
