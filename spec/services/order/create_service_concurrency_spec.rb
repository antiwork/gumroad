# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Each checkout needs its own committed transaction and database connection for this race to be real.
describe Order::CreateService, "once-per-cart concurrency" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @products = [
      create(:product, user: @seller, price_cents: 1_00),
      create(:product, user: @seller, price_cents: 1_00),
    ]
    @offer_code = create(
      :universal_offer_code,
      user: @seller,
      amount_cents: 1_00,
      amount_percentage: nil,
      currency_type: "usd",
      once_per_cart: true,
      max_purchase_count: 1
    )
  end

  after do
    purchase_ids = Purchase.where(seller: @seller).pluck(:id)
    order_ids = OrderPurchase.where(purchase_id: purchase_ids).pluck(:order_id)
    PurchasePaymentFlow.where(purchase_id: purchase_ids).delete_all
    PurchaseSalesTaxInfo.where(purchase_id: purchase_ids).delete_all
    PurchaseOfferCodeDiscount.where(purchase_id: purchase_ids).delete_all
    OrderPurchase.where(purchase_id: purchase_ids).delete_all
    Purchase.where(id: purchase_ids).delete_all
    Order.where(id: order_ids).delete_all
    OfferCode.where(id: @offer_code.id).delete_all
    ActiveRecord::Base.connection.execute("DELETE FROM offer_codes_products WHERE offer_code_id = #{@offer_code.id.to_i}")
    Price.where(link_id: @products).delete_all
    Link.where(id: @products).delete_all
    User.where(id: @seller.id).delete_all
  end

  def params_for(product, uid)
    {
      email: "#{uid}@example.com",
      browser_guid: SecureRandom.uuid,
      ip_address: "0.0.0.0",
      line_items: [{
        uid:,
        permalink: product.unique_permalink,
        perceived_price_cents: 0,
        quantity: 1,
        discount_code: @offer_code.code,
      }],
    }
  end

  it "reserves the final capped use atomically" do
    first_reserved = Queue.new
    release_first = Queue.new
    second_waiting = Queue.new
    connections = Queue.new
    threads = []

    allow_any_instance_of(Purchase).to receive(:calculate_taxes).and_wrap_original do |method, *args|
      raise "tax calculation ran under the offer-code lock" if Thread.current[:inside_offer_code_reservation_lock]

      method.call(*args)
    end
    allow_any_instance_of(OfferCode).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      second_waiting << true if Thread.current[:offer_code_reservation_role] == :second
      method.call(*args) do
        Thread.current[:inside_offer_code_reservation_lock] = true
        result = block.call
        if Thread.current[:offer_code_reservation_role] == :first
          first_reserved << true
          release_first.pop
        end
        result
      ensure
        Thread.current[:inside_offer_code_reservation_lock] = false
      end
    end

    begin
      results = {}
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connections << connection.object_id
          Thread.current[:offer_code_reservation_role] = :first
          results[:first] = described_class.new(params: params_for(@products.first, "first")).perform
        end
      end
      Timeout.timeout(5) { first_reserved.pop }
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connections << connection.object_id
          Thread.current[:offer_code_reservation_role] = :second
          results[:second] = described_class.new(params: params_for(@products.second, "second")).perform
        end
      end
      Timeout.timeout(5) { second_waiting.pop }
      release_first << true
      Timeout.timeout(10) { threads.each(&:value) }

      first_order, first_responses = results.fetch(:first)
      second_order, second_responses = results.fetch(:second)
      expect(2.times.map { connections.pop }.uniq.size).to eq(2)
      expect(first_responses).to be_empty
      expect(first_order.purchases.sole).to be_in_progress
      expect(second_responses.values.sole).to include(success: false, error_code: PurchaseErrorCode::OFFER_CODE_SOLD_OUT)
      expect(second_order.purchases.sole).to be_failed
    ensure
      release_first << true if release_first.empty?
      threads.each { _1.kill if _1.alive? }
    end
  end
end
