# frozen_string_literal: true

require "spec_helper"

describe Product::Stats do
  include ManageSubscriptionHelpers

  describe ".successful_sales_count", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "does not take into account refunded/disputed purchases" do
      @product = create(:product, price_cents: 500)
      create(:purchase, link: @product)
      create(:purchase, link: @product, stripe_refunded: true)
      create(:purchase, link: @product, chargeback_date: Time.current)
      create(:purchase, link: @product, chargeback_date: Time.current, chargeback_reversed: true)

      @preorder_link = create(:product, price_cents: 500, is_in_preorder_state: true)
      create(:purchase, link: @preorder_link, purchase_state: "preorder_authorization_successful")
      create(:purchase, link: @preorder_link, purchase_state: "preorder_authorization_successful", stripe_refunded: true)

      expect(@product.sales.count).to eq 4
      expect(Link.successful_sales_count(products: @product)).to eq 2
      expect(@preorder_link.sales.count).to eq 2
      expect(Link.successful_sales_count(products: @preorder_link)).to eq 1
    end

    context "for tiered memberships" do
      it "does not double count subscriptions that have been upgraded" do
        product = create(:membership_product)
        sub = create(:subscription, link: product)
        create(:purchase, subscription: sub, link: product, is_original_subscription_purchase: true,
                          purchase_state: "successful", is_archived_original_subscription_purchase: true)
        create(:purchase, subscription: sub, link: product, is_original_subscription_purchase: true,
                          purchase_state: "not_charged")
        sub.reload
        create(:purchase, subscription: sub, link: product, is_original_subscription_purchase: false)

        expect(Link.successful_sales_count(products: product)).to eq 1
      end
    end

    it "supports multiple products" do
      products = create_list(:product, 2)
      products.each do |product|
        create(:purchase, link: product)
      end

      expect(Link.successful_sales_count(products: products.map(&:id))).to eq(2)
    end
  end

  describe "#successful_sales_count" do
    it "returns value from the class method" do
      product = create(:product)
      expect(Link).to receive(:successful_sales_count).with(products: product, extra_search_options: nil).and_return(123)
      expect(product.successful_sales_count).to eq(123)
    end
  end

  describe "#total_usd_cents", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "returns net revenue" do
      product = create(:product)
      expect(product.total_usd_cents).to eq(0)

      create_list(:purchase, 2, link: product)
      expect(product.reload.total_usd_cents).to eq(200)
    end

    context "with a created_after option" do
      it "returns the sum of matching net revenue" do
        product = create(:product)
        create(:purchase, link: product, created_at: 5.days.ago)
        create(:purchase, link: product, created_at: 3.days.ago)
        create(:purchase, link: product, created_at: 1.day.ago)

        expect(product.total_usd_cents(created_after: 10.days.ago)).to eq(300)
        expect(product.total_usd_cents(created_after: 4.days.ago)).to eq(200)
        expect(product.total_usd_cents(created_after: 1.minute.ago)).to eq(0)
      end
    end

    it "does not take into account refunded or not charged purchases", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      @product = create(:product, price_cents: 500)
      create(:purchase, link: @product)
      create(:purchase, link: @product, stripe_refunded: true)
      create(:purchase, link: @product, purchase_state: "not_charged")

      @preorder_link = create(:product, price_cents: 500, is_in_preorder_state: true)
      create(:purchase, link: @preorder_link, purchase_state: "preorder_authorization_successful")
      create(:purchase, link: @preorder_link, purchase_state: "preorder_authorization_successful", stripe_refunded: true)

      partially_refunded_purchase = create(:purchase, link: @product, stripe_partially_refunded: true)
      partially_refunded_purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 300), partially_refunded_purchase.seller.id)

      expect(@product.total_usd_cents).to eq 700
      expect(@preorder_link.total_usd_cents).to eq 500
    end
  end

  describe "#total_fee_cents", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "does not take into account fully refunded, not charged, chargeback not reverted, giftee purchases" do
      product = create(:product, price_cents: 500)
      create(:purchase, link: product)
      create(:purchase, link: product, stripe_refunded: true)
      create(:purchase, link: product, stripe_partially_refunded: true)
      create(:purchase, link: product, purchase_state: "not_charged")
      create(:purchase, link: product, chargeback_date: 1.day.ago)
      create(:purchase, link: product, chargeback_date: 1.day.ago, chargeback_reversed: true)
      create(:purchase, link: product, created_at: 2.months.ago)
      create(:gift, link: product,
                    gifter_purchase: create(:purchase, link: product, is_gift_sender_purchase: true),
                    giftee_purchase: create(:purchase, link: product, is_gift_receiver_purchase: true, price_cents: 0, purchase_state: "gift_receiver_purchase_successful"))

      preorder_product = create(:product, price_cents: 500, is_in_preorder_state: true)
      create(:preorder_authorization_purchase, link: preorder_product)
      create(:preorder_authorization_purchase, link: preorder_product, stripe_refunded: true)
      create(:preorder_authorization_purchase, link: preorder_product, stripe_partially_refunded: true)
      create(:preorder_authorization_purchase, link: preorder_product, chargeback_date: 1.day.ago)
      create(:preorder_authorization_purchase, link: preorder_product, chargeback_date: 1.day.ago, chargeback_reversed: true)
      create(:gift, link: preorder_product,
                    gifter_purchase: create(:preorder_authorization_purchase, link: preorder_product, is_gift_sender_purchase: true),
                    giftee_purchase: create(:preorder_authorization_purchase, link: preorder_product, is_gift_receiver_purchase: true, price_cents: 0, purchase_state: "gift_receiver_purchase_successful"))

      # successful + partially refunded + chargeback reversed + gift sender purchases - (4*75)
      expect(product.total_fee_cents(created_after: 1.month.ago)).to eq 580
      expect(preorder_product.total_fee_cents).to eq 580
    end

    it "returns net fees" do
      product = create(:product)
      expect(product.total_fee_cents).to eq(0)

      create_list(:purchase, 2, :with_custom_fee, link: product, fee_cents: 15)
      expect(product.reload.total_fee_cents).to eq(30)
    end

    context "with a created_after option" do
      it "returns the sum of matching net revenue" do
        product = create(:product)
        create(:purchase, :with_custom_fee, link: product, created_at: 5.days.ago, fee_cents: 15)
        create(:purchase, :with_custom_fee, link: product, created_at: 3.days.ago, fee_cents: 15)
        create(:purchase, :with_custom_fee, link: product, created_at: 1.day.ago, fee_cents: 15)

        expect(product.total_fee_cents(created_after: 10.days.ago)).to eq(45)
        expect(product.total_fee_cents(created_after: 4.days.ago)).to eq(30)
        expect(product.total_fee_cents(created_after: 1.minute.ago)).to eq(0)
      end
    end
  end

  describe "#pending_balance" do
    before do
      @product = create(:subscription_product, user: create(:user), duration_in_months: 12)
      @sub = create(:subscription, user: create(:user), link: @product, charge_occurrence_count: 12)
      @original_purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription: @sub)
    end

    it "returns the correct pending balance" do
      expect(@product.pending_balance).to eq 1100
    end

    it "shoud return $0 if there are no pending balances" do
      @sub.update_attribute(:cancelled_at, Time.current)
      expect(@product.pending_balance).to eq 0
    end

    context "when a subscription has been updated" do
      it "uses the updated purchase price" do
        @original_purchase.update!(is_archived_original_subscription_purchase: true)
        create(:purchase, link: @product, price_cents: @product.price_cents + 100, is_original_subscription_purchase: true, subscription: @sub, purchase_state: "not_charged")

        expect(@product.pending_balance).to eq 2200
      end
    end
  end

  describe "#revenue_pending" do
    context "when product has a duration set" do
      before do
        @product = create(:subscription_product, user: create(:user), duration_in_months: 12)
        subscription = create(:subscription, link: @product, charge_occurrence_count: 12)
        @original_purchase = create(:purchase, link: @product, price_cents: @product.price_cents, is_original_subscription_purchase: true, subscription:)
      end

      it "returns the correct pending revenue" do
        expect(@product.revenue_pending).to eq 1100
      end
    end

    context "when product has no duration set" do
      before do
        @product = create(:product)
      end

      it "returns 0" do
        expect(@product.revenue_pending).to eq 0
      end
    end
  end

  describe ".monthly_recurring_revenue", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    subject { Link.monthly_recurring_revenue(products: [@product]) }

    context "for a non-tiered subscription product" do
      before do
        @product = create(:subscription_product, user: create(:user))
        price_monthly = create(:price, link: @product, price_cents: 10_00, recurrence: BasePrice::Recurrence::MONTHLY)
        price_yearly = create(:price, link: @product, price_cents: 100_00, recurrence: BasePrice::Recurrence::YEARLY)
        sub_monthly = create(:subscription, user: create(:user), link: @product)
        sub_monthly.payment_options.create(price: price_monthly)
        create(:purchase, link: @product, price_cents: 10_00, is_original_subscription_purchase: true, subscription: sub_monthly)
        @sub_yearly = create(:subscription, user: create(:user), link: @product)
        @sub_yearly.payment_options.create(price: price_yearly)
        create(:purchase, link: @product, price_cents: 100_00, is_original_subscription_purchase: true, subscription: @sub_yearly)
      end

      it "returns the monthly recurring revenue" do
        is_expected.to eq 1833.3333129882812
      end

      it "discards inactive subscriptions" do
        @sub_yearly.update_attribute(:cancelled_at, Time.current)
        is_expected.to eq 1000
      end
    end

    context "for a tiered membership product", :vcr do
      before do
        # create two subscriptions:
        # - monthly @ $3
        # - yearly @ $10
        shared_setup
        @sub_monthly = create_subscription(product_price: @monthly_product_price,
                                           tier: @original_tier,
                                           tier_price: @original_tier_monthly_price)
        @sub_yearly = create_subscription(product_price: @yearly_product_price,
                                          tier: @original_tier,
                                          tier_price: @original_tier_yearly_price)
      end

      it "returns the monthly recurring revenue" do
        is_expected.to eq 383.33333587646484
      end

      it "discards inactive subscriptions" do
        @sub_yearly.update_attribute(:cancelled_at, Time.current)
        is_expected.to eq 300
      end

      context "with a subscription that has been upgraded" do
        it "uses the new 'original' purchase" do
          travel_to(@originally_subscribed_at + 1.year + 1.day) do
            params = {
              price_id: @yearly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_yearly_price.price_cents,
              perceived_upgrade_price_cents: @original_tier_yearly_price.price_cents,
            }
            result = Subscription::UpdaterService.new(subscription: @sub_monthly,
                                                      gumroad_guid: "abc123",
                                                      params:,
                                                      logged_in_user: @sub_monthly.user,
                                                      remote_ip: "1.1.1.1").perform
            expect(result[:success]).to eq true

            # Two yearly $10 subscriptions
            is_expected.to eq 166.6666717529297
          end
        end
      end

      shared_examples "common cancelled MRR" do
        it "returns only the active subscriptions" do
          # One yearly $10 subscription
          is_expected.to eq 83.33333587646484
        end
      end

      context "with a subscription cancelled by buyer but still active" do
        before do
          @sub_monthly.update!(
            cancelled_by_buyer: true,
            cancelled_at: @sub_monthly.created_at + 1.month
          )
        end

        include_examples "common cancelled MRR"
      end

      context "with a subscription cancelled by admin but still active" do
        before do
          @sub_monthly.update!(
            cancelled_by_admin: true,
            cancelled_at: @sub_monthly.created_at + 1.month
          )
        end

        include_examples "common cancelled MRR"
      end

      context "with a cancelled subscription" do
        before do
          @sub_monthly.update!(
            cancelled_by_buyer: true,
            cancelled_at: 1.day.ago
          )
        end

        include_examples "common cancelled MRR"
      end

      context "when multiple tiered membership products exist" do
        before do
          product = create(:membership_product_with_preset_tiered_pricing, user: @user)
          create(:membership_purchase,
                 link: product,
                 price_cents: 1000,
                 variant_attributes: [product.default_tier])
        end

        it "does not count subscriptions from other products" do
          is_expected.to eq 383.33333587646484
        end
      end
    end

    it "supports multiple products" do
      products = create_list(:subscription_product, 2)
      products.each do |product|
        price_monthly = create(:price, link: product, price_cents: 10_00, recurrence: BasePrice::Recurrence::MONTHLY)
        sub_monthly = create(:subscription, link: product)
        sub_monthly.payment_options.create(price: price_monthly)
        create(:purchase, link: product, price_cents: 10_00, is_original_subscription_purchase: true, subscription: sub_monthly)
      end

      expect(Link.monthly_recurring_revenue(products: products.map(&:id))).to eq(20_00)
    end
  end

  describe "#monthly_recurring_revenue" do
    it "returns monthly recurring revenue from the class method" do
      product = create(:product)
      expect(Link).to receive(:monthly_recurring_revenue).with(products: product).and_return(123)
      expect(product.monthly_recurring_revenue).to eq(123)
    end
  end

  describe "#number_of_views" do
    it "returns the views total", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      product = create(:product)
      2.times { add_page_view(product) }
      expect(product.number_of_views).to eq(2)
    end
  end
end
