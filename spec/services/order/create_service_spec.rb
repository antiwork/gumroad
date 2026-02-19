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

    it "does not delete the cart when all line items fail" do
      failed_params = {
        line_items: [
          { uid: "unique-id-0", permalink: "non-existent", perceived_price_cents: 500, quantity: 1 },
          { uid: "unique-id-1", permalink: "also-non-existent", perceived_price_cents: 500, quantity: 1 }
        ]
      }.merge(common_order_params_without_payment)

      buyer = create(:user, email: "buyer@gumroad.com")
      cart = create(:cart, user: buyer, browser_guid:)

      order, purchase_responses, _ = Order::CreateService.new(params: failed_params, buyer:).perform

      expect(order).not_to be_persisted
      expect(purchase_responses.values).to all(include(success: false))
      expect(cart.reload).to be_alive
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

    context "when a line item has a restartable subscription" do
      let(:membership_product) { create(:membership_product, user: seller_1, price_cents: price_1) }
      let(:buyer) { create(:user, email: "buyer@gumroad.com") }
      let!(:subscription) do
        sub = create(:subscription, link: membership_product, user: buyer)
        create(:purchase,
               link: membership_product,
               purchaser: buyer,
               email: buyer.email,
               subscription: sub,
               is_original_subscription_purchase: true,
               price_cents: membership_product.price_cents,
               variant_attributes: membership_product.tiers.to_a
        )
        sub.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)
        sub
      end

      let(:params_with_membership) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: membership_product.price_cents,
              quantity: 1,
              price_id: membership_product.prices.alive.first.external_id
            },
            {
              uid: "unique-id-1",
              permalink: product_2.unique_permalink,
              perceived_price_cents: product_2.price_cents,
              quantity: 1
            }
          ]
        }.merge(common_order_params_without_payment)
      end

      it "passes stripe_customer_id and stripe_setup_intent_id through to the subscription restart in a multi-seller cart" do
        # In a multi-seller cart, prepareFutureCharges() creates a SetupIntent and the
        # customer completes SCA upfront. The resulting stripe_customer_id and
        # stripe_setup_intent_id must reach UpdaterService so the restart charge can
        # reference the prior authentication and avoid a second SCA prompt.
        multi_seller_params = {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: membership_product.price_cents,
              quantity: 1,
              price_id: membership_product.prices.alive.first.external_id
            },
            {
              uid: "unique-id-1",
              permalink: product_4.unique_permalink,
              perceived_price_cents: product_4.price_cents,
              quantity: 1
            }
          ],
          stripe_payment_method_id: "pm_123",
          stripe_customer_id: "cus_123",
          stripe_setup_intent_id: "seti_123",
          card_data_handling_mode: "stripe_elements"
        }.merge(common_order_params_without_payment)

        updater_service = instance_double(Subscription::UpdaterService)
        expect(Subscription::UpdaterService).to receive(:new).with(
          subscription: subscription,
          params: hash_including(
            stripe_customer_id: "cus_123",
            stripe_setup_intent_id: "seti_123",
            stripe_payment_method_id: "pm_123"
          ),
          logged_in_user: buyer,
          gumroad_guid: browser_guid,
          remote_ip: anything
        ).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        order, purchase_responses, _ = Order::CreateService.new(params: multi_seller_params, buyer:).perform

        expect(purchase_responses["unique-id-0"]).to include(success: true)
        # The regular product from seller_2 should still be in the order
        expect(order.purchases.in_progress.count).to eq(1)
        expect(order.purchases.first.link).to eq(product_4)
      end

      it "does not add the restarted subscription's original purchase to the order" do
        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        order, purchase_responses, _ = Order::CreateService.new(params: params_with_membership, buyer:).perform

        # The restarted subscription's purchase should NOT be in the order
        expect(order.purchases.map(&:id)).not_to include(subscription.original_purchase.id)
        # But we should have a success response for the membership line item
        expect(purchase_responses["unique-id-0"]).to include(success: true)
        # The regular product should still be in the order
        expect(order.purchases.in_progress.count).to eq(1)
      end

      it "includes the regular purchase in the order" do
        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        order, _, _ = Order::CreateService.new(params: params_with_membership, buyer:).perform

        expect(order.purchases.count).to eq(1)
        expect(order.purchases.first.link).to eq(product_2)
      end

      it "passes through SCA data when the restart requires card action" do
        merchant_account = create(:merchant_account_stripe_connect, user: membership_product.user)

        upgrade_purchase = create(:purchase_in_progress,
                                  link: membership_product,
                                  purchaser: buyer,
                                  email: buyer.email,
                                  subscription: subscription,
                                  price_cents: membership_product.price_cents)

        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({
                                                                 success: true,
                                                                 requires_card_action: true,
                                                                 client_secret: "pi_123_secret_456",
                                                                 purchase: { id: upgrade_purchase.external_id, stripe_connect_account_id: merchant_account.charge_processor_merchant_id }
                                                               })

        order, purchase_responses, _ = Order::CreateService.new(params: params_with_membership, buyer:).perform

        sca_response = purchase_responses["unique-id-0"]
        expect(sca_response).to include(
          requires_card_action: true,
          client_secret: "pi_123_secret_456"
        )
        expect(sca_response[:order][:id]).to eq(order.external_id)
        expect(sca_response[:order][:stripe_connect_account_id]).to eq(merchant_account.charge_processor_merchant_id)
        # The SCA upgrade purchase is added to the order for the confirm endpoint
        expect(order.purchases.in_progress.count).to eq(2)
        expect(order.purchases.in_progress.map(&:link)).to include(membership_product, product_2)
      end

      it "SCA response can be confirmed via Purchase::ConfirmService" do
        # Simulate the state after UpdaterService ran: subscription alive but pending SCA confirmation
        subscription.update!(cancelled_at: nil, deactivated_at: nil)
        subscription.update_flag!(:cancelled_by_buyer, false, true)
        subscription.update_flag!(:is_resubscription_pending_confirmation, true, true)

        upgrade_purchase = create(:purchase_in_progress,
                                  link: membership_product,
                                  purchaser: buyer,
                                  email: buyer.email,
                                  subscription: subscription,
                                  price_cents: membership_product.price_cents)

        allow(upgrade_purchase).to receive(:confirm_charge_intent!)

        error = Purchase::ConfirmService.new(purchase: upgrade_purchase, params: {}).perform

        expect(error).to be_nil
        expect(upgrade_purchase.reload).to be_successful
        expect(subscription.reload).not_to be_is_resubscription_pending_confirmation
      end

      it "cleans up the cart when all line items are subscription restarts" do
        restart_only_params = {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: membership_product.price_cents,
              quantity: 1,
              price_id: membership_product.prices.alive.first.external_id
            }
          ]
        }.merge(common_order_params_without_payment)

        cart = create(:cart, user: buyer, browser_guid:)

        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        order, purchase_responses, _ = Order::CreateService.new(params: restart_only_params, buyer:).perform

        expect(order).not_to be_persisted
        expect(purchase_responses["unique-id-0"]).to include(success: true)
        expect(cart.reload).to be_deleted
      end
    end

    context "when a line item has an active subscription" do
      let(:membership_product) { create(:membership_product, user: seller_1, price_cents: price_1) }
      let(:buyer) { create(:user, email: "buyer@gumroad.com") }
      let!(:subscription) do
        sub = create(:subscription, link: membership_product, user: buyer)
        create(:purchase,
               link: membership_product,
               purchaser: buyer,
               email: buyer.email,
               subscription: sub,
               is_original_subscription_purchase: true,
               price_cents: membership_product.price_cents,
               variant_attributes: membership_product.tiers.to_a
        )
        sub
      end

      let(:params_with_active_membership) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: membership_product.price_cents,
              quantity: 1,
              price_id: membership_product.prices.alive.first.external_id
            },
            {
              uid: "unique-id-1",
              permalink: product_2.unique_permalink,
              perceived_price_cents: product_2.price_cents,
              quantity: 1
            }
          ]
        }.merge(common_order_params_without_payment)
      end

      it "returns an error for the membership line item" do
        order, purchase_responses, _ = Order::CreateService.new(params: params_with_active_membership, buyer:).perform

        expect(purchase_responses["unique-id-0"]).to include(success: false)
        # The regular product should still be in the order
        expect(order.purchases.in_progress.count).to eq(1)
      end
    end
  end
end
