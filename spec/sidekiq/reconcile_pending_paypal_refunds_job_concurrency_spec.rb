# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe ReconcilePendingPaypalRefundsJob, "concurrency" do
  self.use_transactional_tests = false

  before do
    allow_any_instance_of(Purchase).to receive(:update_creator_analytics_cache)
    allow_any_instance_of(Purchase).to receive(:send_to_elasticsearch)
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @merchant_account = create(:merchant_account_paypal, user: @seller)
    @purchase = create(:purchase, link: @product, seller: @seller, merchant_account: @merchant_account,
                                  charge_processor_id: PaypalChargeProcessor.charge_processor_id)
    @refund = create(:refund, purchase: @purchase, refunding_user_id: @seller.id,
                              status: "PENDING", processor_refund_id: "concurrent_refund", created_at: 5.days.ago)
  end

  after do
    Refund.where(id: @refund.id).delete_all
    Event.where(purchase_id: @purchase.id).delete_all
    UrlRedirect.where(purchase_id: @purchase.id).delete_all
    Purchase.where(id: @purchase.id).delete_all
    MerchantAccount.where(id: @merchant_account.id).delete_all
    Price.where(link_id: @product.id).delete_all
    @product.destroy!
    Affiliate.where(affiliate_user_id: @seller.id).delete_all
    RefundPolicy.where(seller_id: @seller.id).delete_all
    @seller.destroy!
  end

  it "notifies once when overlapping passes have both loaded the unmarked refund" do
    ready = Queue.new
    release = Queue.new
    notified = Queue.new
    allow(PaypalChargeProcessor).to receive(:fetch_refund_status) do
      ready << ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()")
      release.pop
      raise ChargeProcessorError, "401|closed_user"
    end
    allow(ErrorNotifier).to receive(:notify) do |error, **context|
      raise error unless context.dig(:context, :paypal_refund_unreadable)
      notified << true
    end

    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { described_class.new.perform }
      end
    end
    connection_ids = Timeout.timeout(10) { 2.times.map { ready.pop } }
    expect(connection_ids.uniq.size).to eq(2)
    2.times { release << true }
    Timeout.timeout(10) { workers.each(&:value) }

    expect(notified.size).to eq(1)
    expect(@refund.reload.paypal_refund_unreadable_at).to be_present
    expect(@refund.status).to eq("PENDING")
  ensure
    2.times { release << true }
    workers&.each do |worker|
      next if worker.join(1)
      worker.kill
      worker.join
    end
  end
end
