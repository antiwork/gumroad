# frozen_string_literal: false

require "shared_examples/order_association_with_cart_post_checkout"

describe Order::CreateService, :vcr do
  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:price_1) { 5_00 }
  let(:price_2) { 10_00 }
  let(:price_3) { 10_00 }
  let(:price_4) { 10_00 }
  let(:price_5) { 10_00 }
  let(:product_1) { create(:product, user: seller_1, price_cents: price_1) }
  let(:product_2) { create(:product, user: seller_1, price_cents: price_2) }
  let(:product_3) { create(:product, user: seller_1, price_cents: price_3) }
  let(:product_4) { create(:product, user: seller_2, price_cents: price_4) }
  let(:product_5) { create(:product, user: seller_2, price_cents: price_5, discover_fee_per_thousand: 300) }
  let(:browser_guid) { SecureRandom.uuid }
  let(:common_order_params_without_payment) do
    {
      email: "buyer@gumroad.com",
      cc_zipcode: "12345",
      purchase: {
        full_name: "Edgar Gumstein",
        street_address: "123 Gum Road",
        country: "US",
        state: "CA",
        city: "San Francisco",
        zip_code: "94117"
      },
      browser_guid:,
      ip_address: "0.0.0.0",
      session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
      is_mobile: false,
    }
  end
  let(:params) do
    {
      line_items: [
        {
          uid: "unique-id-0",
          permalink: product_1.unique_permalink,
          perceived_price_cents: product_1.price_cents,
          quantity: 1
        },
        {
          uid: "unique-id-1",
          permalink: product_2.unique_permalink,
          perceived_price_cents: product_2.price_cents,
          quantity: 1
        },
        {
          uid: "unique-id-2",
          permalink: product_3.unique_permalink,
          perceived_price_cents: product_3.price_cents,
          quantity: 1
        },
        {
          uid: "unique-id-3",
          permalink: product_4.unique_permalink,
          perceived_price_cents: product_4.price_cents,
          quantity: 1
        },
        {
          uid: "unique-id-4",
          permalink: product_5.unique_permalink,
          perceived_price_cents: product_5.price_cents,
          quantity: 1
        }
      ]
    }.merge(common_order_params_without_payment)
  end

  describe "#perform" do
    it "creates an order along with the associated purchases in progress" do
      expect do
        expect do
          expect do
            order, _ = Order::CreateService.new(params:).perform

            expect(order.purchases.in_progress.count).to eq 5
          end.to change { Order.count }.by 1
        end.not_to change { Charge.count }
      end.to change { Purchase.count }.by 5
    end

    it "calls Purchase::CreateService for all line items in params with is_part_of_combined_charge set to true" do
      params[:line_items].each do |line_item_params|
        expect(Purchase::CreateService).to receive(:new).with(product: Link.find_by(unique_permalink: line_item_params[:permalink]),
                                                              params: hash_including(is_part_of_combined_charge: true),
                                                              buyer: nil).and_call_original
      end

      order, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.in_progress.count).to eq 5
      expect(order.purchases.is_part_of_combined_charge.count).to eq 5
    end

    it "sets all the common fields on all purchases correctly" do
      order, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.in_progress.count).to eq 5
      expect(order.purchases.pluck(:email).uniq).to eq([common_order_params_without_payment[:email]])
      expect(order.purchases.pluck(:browser_guid).uniq).to eq([common_order_params_without_payment[:browser_guid]])
      expect(order.purchases.pluck(:session_id).uniq).to eq([common_order_params_without_payment[:session_id]])
      expect(order.purchases.pluck(:is_mobile).uniq).to eq([common_order_params_without_payment[:is_mobile]])
      expect(order.purchases.pluck(:ip_address).uniq).to eq([common_order_params_without_payment[:ip_address]])
      expect(order.purchases.pluck(:full_name).uniq).to eq([common_order_params_without_payment[:purchase][:full_name]])
      expect(order.purchases.pluck(:street_address).uniq).to eq([common_order_params_without_payment[:purchase][:street_address]])
      expect(order.purchases.pluck(:state).uniq).to eq([common_order_params_without_payment[:purchase][:state]])
      expect(order.purchases.pluck(:city).uniq).to eq([common_order_params_without_payment[:purchase][:city]])
      expect(order.purchases.pluck(:zip_code).uniq).to eq([common_order_params_without_payment[:purchase][:zip_code]])
    end

    it "sets the buyer when provided" do
      buyer = create(:user, email: "buyer@gumroad.com")

      order, _ = Order::CreateService.new(params:, buyer:).perform

      expect(order.purchaser).to eq buyer
    end

    it_behaves_like "order association with cart post checkout" do
      let(:user) { create(:buyer_user) }
      let(:sign_in_user_action) { @signed_in = true }
      let(:call_action) { Order::CreateService.new(params:, buyer: @signed_in ? user : nil).perform }
      let(:browser_guid) { "123" }

      before do
        params[:browser_guid] = browser_guid
      end
    end

    it "saves the referrer info correctly" do
      params[:line_items][0][:referrer] = "https://facebook.com"
      params[:line_items][1][:referrer] = "https://google.com"

      order, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.first.referrer).to eq "https://facebook.com"
      expect(order.purchases.second.referrer).to eq "https://google.com"
    end

    it "returns failure responses with correct errors for purchases that fail" do
      product_2.update!(max_purchase_count: 2)
      params[:line_items][1][:quantity] = 3
      params[:line_items][3][:permalink] = "non-existent"

      order, purchase_responses, _ = Order::CreateService.new(params:).perform

      expect(order.purchases.count).to eq(4)
      expect(order.purchases.in_progress.count).to eq(3)
      expect(order.purchases.failed.count).to eq(1)

      expect(purchase_responses.size).to eq(2)
      expect(purchase_responses[params[:line_items][1][:uid]]).to include(
                                                                    success: false,
                                                                    error_message: "You have chosen a quantity that exceeds what is available.",
                                                                    name: "The Works of Edgar Gumstein",
                                                                    error_code: "exceeding_product_quantity")
      expect(purchase_responses[params[:line_items][3][:uid]]).to include(
                                                                    success: false,
                                                                    error_message: "Product not found",
                                                                    name: nil,
                                                                    error_code: nil)
    end

    it "creates an order along with the associated purchases in progress when merchant account is a Brazilian Stripe Connect account" do
      seller_2.update!(check_merchant_account_is_linked: true)
      create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1QADdCGy0w4tFIUe", country: "BR", user: seller_2)

      expect do
        expect do
          expect do
            order, _ = Order::CreateService.new(params:).perform

            expect(order.purchases.in_progress.count).to eq 5
          end.to change { Order.count }.by 1
        end.not_to change { Charge.count }
      end.to change { Purchase.count }.by 5
    end

    describe "existing active subscription check" do
      # See: https://github.com/antiwork/gumroad/issues/173
      let(:membership_product) { create(:membership_product, user: seller_1) }
      let(:buyer) { create(:user, email: "buyer@gumroad.com") }

      # Helper to create subscription without triggering card charge
      def create_subscription_for_product(product:, purchaser:, email:, **subscription_attrs)
        subscription = create(:subscription, link: product, user: purchaser)
        create(:purchase,
               link: product,
               purchaser: purchaser,
               email: email,
               subscription: subscription,
               is_original_subscription_purchase: true,
               price_cents: product.price_cents,
               variant_attributes: product.tiers.to_a
        )
        subscription.update!(subscription_attrs) if subscription_attrs.present?
        subscription
      end

      let(:membership_line_item) do
        tier = membership_product.tiers.first
        {
          uid: "membership-uid",
          permalink: membership_product.unique_permalink,
          perceived_price_cents: tier.prices.alive.first.price_cents,
          quantity: 1,
          price_id: membership_product.prices.alive.first.external_id,
          variants: [tier.external_id]
        }
      end

      let(:membership_params) do
        common_order_params_without_payment.merge(
          line_items: [membership_line_item]
        )
      end

      context "when signed-in buyer has an active subscription" do
        let!(:existing_subscription) do
          create_subscription_for_product(
            product: membership_product,
            purchaser: buyer,
            email: buyer.email
          )
        end

        it "returns helpful error for signed-in user and sends notification email" do
          expect(CustomerLowPriorityMailer).to receive(:already_subscribed_checkout_attempt)
            .with(existing_subscription.id)
            .and_return(double(deliver_later: true))

          _order, purchase_responses, _ = Order::CreateService.new(params: membership_params, buyer: buyer).perform

          expect(purchase_responses["membership-uid"]).to include(
            success: false,
            error_message: "You already have an active subscription to this membership. Visit your Library to manage it."
          )
        end

        it "does not create a purchase for the membership" do
          allow(CustomerLowPriorityMailer).to receive(:already_subscribed_checkout_attempt)
            .and_return(double(deliver_later: true))

          expect do
            Order::CreateService.new(params: membership_params, buyer: buyer).perform
          end.not_to change { Purchase.count }
        end
      end

      context "when signed-out user tries to purchase with email that has active subscription" do
        let!(:existing_subscription) do
          create_subscription_for_product(
            product: membership_product,
            purchaser: create(:user),
            email: "buyer@gumroad.com"
          )
        end

        it "returns generic error for signed-out user (privacy)" do
          allow(CustomerLowPriorityMailer).to receive(:already_subscribed_checkout_attempt)
            .and_return(double(deliver_later: true))
          allow(Bugsnag).to receive(:notify)

          _order, purchase_responses, _ = Order::CreateService.new(params: membership_params, buyer: nil).perform

          expect(purchase_responses["membership-uid"]).to include(
            success: false,
            error_message: "Sorry, something went wrong. Please try again."
          )
        end

        it "notifies Bugsnag for monitoring" do
          allow(CustomerLowPriorityMailer).to receive(:already_subscribed_checkout_attempt)
            .and_return(double(deliver_later: true))

          expect(Bugsnag).to receive(:notify).with(an_instance_of(StandardError)) do |error, &block|
            expect(error.message).to eq("Existing subscription checkout attempt")
          end

          Order::CreateService.new(params: membership_params, buyer: nil).perform
        end

        it "sends notification email to subscriber" do
          allow(Bugsnag).to receive(:notify)

          expect(CustomerLowPriorityMailer).to receive(:already_subscribed_checkout_attempt)
            .with(existing_subscription.id)
            .and_return(double(deliver_later: true))

          Order::CreateService.new(params: membership_params, buyer: nil).perform
        end
      end

      context "when user has no active subscription" do
        it "proceeds to create the purchase normally" do
          expect(Purchase::CreateService).to receive(:new).and_call_original

          order, purchase_responses, _ = Order::CreateService.new(params: membership_params, buyer: buyer).perform

          expect(purchase_responses["membership-uid"]).to be_nil
          expect(order.purchases.count).to eq(1)
        end
      end

      context "when purchase is a gift" do
        let(:gift_membership_params) do
          membership_params.tap do |p|
            p[:line_items][0][:is_gift] = true
            p[:is_gift] = true
            p[:giftee_email] = "giftee@example.com"
          end
        end

        let!(:giftee_subscription) do
          create_subscription_for_product(
            product: membership_product,
            purchaser: create(:user),
            email: "giftee@example.com"
          )
        end

        it "skips the active subscription check for gifts" do
          expect(Subscription).not_to receive(:active_for_user_and_product)

          Order::CreateService.new(params: gift_membership_params, buyer: buyer).perform
        end
      end
    end
  end
end
