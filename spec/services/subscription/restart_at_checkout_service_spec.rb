# frozen_string_literal: true

describe Subscription::RestartAtCheckoutService do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }
  let(:buyer) { create(:user) }
  let(:email) { buyer.email }
  let(:browser_guid) { SecureRandom.uuid }

  let(:base_params) do
    {
      purchase: {
        email: email,
        perceived_price_cents: product.price_cents,
        browser_guid: browser_guid
      },
      price_id: product.prices.alive.first.external_id,
      remote_ip: "127.0.0.1"
    }
  end

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

  describe "#perform" do
    describe "delegation to UpdaterService" do
      let!(:subscription) do
        create_subscription_for_product(
          product: product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "delegates to Subscription::UpdaterService with transformed params" do
        updater_service = instance_double(Subscription::UpdaterService)
        expect(Subscription::UpdaterService).to receive(:new).with(
          subscription: subscription,
          params: hash_including(
            :variants,
            :price_id,
            :perceived_price_cents,
            :perceived_upgrade_price_cents,
            :use_existing_card
          ),
          logged_in_user: buyer,
          gumroad_guid: browser_guid,
          remote_ip: "127.0.0.1"
        ).and_return(updater_service)

        expect(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        ).perform
      end

      it "transforms checkout params to UpdaterService format" do
        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        # Use send to test private method
        transformed_params = service.send(:updater_service_params)

        expect(transformed_params[:perceived_price_cents]).to eq(product.price_cents)
        expect(transformed_params[:perceived_upgrade_price_cents]).to eq(product.price_cents)
        expect(transformed_params[:price_id]).to eq(product.prices.alive.first.external_id)
        expect(transformed_params[:use_existing_card]).to be true
      end

      it "forwards stripe_customer_id and stripe_setup_intent_id to UpdaterService" do
        params_with_stripe = base_params.merge(
          stripe_payment_method_id: "pm_123",
          stripe_customer_id: "cus_123",
          stripe_setup_intent_id: "seti_123",
          card_data_handling_mode: "stripe_elements"
        )

        service = described_class.new(
          subscription: subscription,
          product: product,
          params: params_with_stripe,
          buyer: buyer
        )

        transformed_params = service.send(:updater_service_params)

        expect(transformed_params[:stripe_customer_id]).to eq("cus_123")
        expect(transformed_params[:stripe_setup_intent_id]).to eq("seti_123")
        expect(transformed_params[:stripe_payment_method_id]).to eq("pm_123")
      end

      it "uses default variants when not provided in params" do
        params_without_variants = base_params.except(:variants)

        service = described_class.new(
          subscription: subscription,
          product: product,
          params: params_without_variants,
          buyer: buyer
        )

        transformed_params = service.send(:updater_service_params)
        expected_variant_ids = subscription.original_purchase.variant_attributes.map(&:external_id)

        expect(transformed_params[:variants]).to eq(expected_variant_ids)
      end
    end

    describe "result adaptation" do
      let!(:subscription) do
        create_subscription_for_product(
          product: product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "adapts successful result with restarted_subscription flag" do
        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({
                                                                 success: true,
                                                                 success_message: "Membership restarted"
                                                               })

        result = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        ).perform

        expect(result[:success]).to be true
        expect(result[:restarted_subscription]).to be true
        expect(result[:subscription]).to eq(subscription)
        expect(result[:message]).to eq("Membership restarted")
      end

      it "adapts error result" do
        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({
                                                                 success: false,
                                                                 error_message: "Something went wrong"
                                                               })

        result = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        ).perform

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Something went wrong")
      end

      it "includes requires_card_action when present" do
        updater_service = instance_double(Subscription::UpdaterService)
        allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
        allow(updater_service).to receive(:perform).and_return({
                                                                 success: true,
                                                                 requires_card_action: true,
                                                                 client_secret: "secret_123"
                                                               })

        result = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        ).perform

        expect(result[:requires_card_action]).to be true
        expect(result[:client_secret]).to eq("secret_123")
      end
    end

    describe "recurrence change (issue #117)" do
      let!(:subscription) do
        create_subscription_for_product(
          product: product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      let(:yearly_price) { create(:price, link: product, recurrence: "yearly", price_cents: 100_00) }

      it "passes the new price_id to UpdaterService when changing recurrence" do
        params_with_yearly = base_params.merge(price_id: yearly_price.external_id)

        updater_service = instance_double(Subscription::UpdaterService)
        expect(Subscription::UpdaterService).to receive(:new).with(
          subscription: subscription,
          params: hash_including(price_id: yearly_price.external_id),
          logged_in_user: buyer,
          gumroad_guid: browser_guid,
          remote_ip: "127.0.0.1"
        ).and_return(updater_service)

        expect(updater_service).to receive(:perform).and_return({ success: true })

        described_class.new(
          subscription: subscription,
          product: product,
          params: params_with_yearly,
          buyer: buyer
        ).perform
      end
    end

    describe "quantity passthrough" do
      let(:expensive_product) { create(:membership_product, user: seller, price_cents: 10_00) }
      let!(:subscription) do
        create_subscription_for_product(
          product: expensive_product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "uses params[:quantity] when provided" do
        subscription.original_purchase.update!(quantity: 3)

        service = described_class.new(
          subscription: subscription,
          product: expensive_product,
          params: base_params.merge(price_id: expensive_product.prices.alive.first.external_id, quantity: "5"),
          buyer: buyer
        )

        transformed_params = service.send(:updater_service_params)

        expect(transformed_params[:quantity]).to eq(5)
      end

      it "falls back to original purchase quantity when params[:quantity] is not provided" do
        subscription.original_purchase.update!(quantity: 3)

        service = described_class.new(
          subscription: subscription,
          product: expensive_product,
          params: base_params.merge(price_id: expensive_product.prices.alive.first.external_id),
          buyer: buyer
        )

        transformed_params = service.send(:updater_service_params)

        expect(transformed_params[:quantity]).to eq(3)
      end

      it "passes quantity of 1 for single-quantity subscriptions" do
        service = described_class.new(
          subscription: subscription,
          product: expensive_product,
          params: base_params.merge(price_id: expensive_product.prices.alive.first.external_id),
          buyer: buyer
        )

        transformed_params = service.send(:updater_service_params)

        expect(transformed_params[:quantity]).to eq(1)
      end
    end

    describe "offer code resolution" do
      let(:expensive_product) { create(:membership_product, user: seller, price_cents: 10_00) }

      let!(:subscription) do
        create_subscription_for_product(
          product: expensive_product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      let(:offer_code_params) do
        {
          purchase: {
            email: email,
            perceived_price_cents: expensive_product.price_cents,
            browser_guid: browser_guid
          },
          price_id: expensive_product.prices.alive.first.external_id,
          remote_ip: "127.0.0.1"
        }
      end

      context "when no discount code is entered" do
        it "does not include offer_code in params" do
          service = described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          )

          transformed_params = service.send(:updater_service_params)

          expect(transformed_params).not_to have_key(:offer_code)
        end

        it "sets clear_discount to true when the original purchase has a discount" do
          offer_code = create(:offer_code, amount_cents: nil, amount_percentage: 25, products: [expensive_product], user: seller)
          original_purchase = subscription.original_purchase
          original_purchase.update!(offer_code: offer_code)
          original_purchase.create_purchase_offer_code_discount!(
            offer_code: offer_code,
            offer_code_amount: 25,
            offer_code_is_percent: true,
            pre_discount_minimum_price_cents: original_purchase.minimum_paid_price_cents_per_unit_before_discount
          )

          service = described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          )

          transformed_params = service.send(:updater_service_params)

          expect(transformed_params[:clear_discount]).to eq(true)
        end

        it "sets clear_discount to false when the original purchase has no discount" do
          service = described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          )

          transformed_params = service.send(:updater_service_params)

          expect(transformed_params[:clear_discount]).to eq(false)
        end
      end

      context "when a valid discount code is entered" do
        let(:offer_code) { create(:offer_code, amount_cents: nil, amount_percentage: 40, products: [expensive_product], user: seller) }

        it "passes the offer code to UpdaterService" do
          params_with_discount = offer_code_params.deep_merge(
            purchase: { discount_code: offer_code.code }
          )

          service = described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: params_with_discount,
            buyer: buyer
          )

          transformed_params = service.send(:updater_service_params)

          expect(transformed_params[:offer_code]).to eq(offer_code)
        end

        it "sets clear_discount to false when an offer code is entered" do
          params_with_discount = offer_code_params.deep_merge(
            purchase: { discount_code: offer_code.code }
          )

          service = described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: params_with_discount,
            buyer: buyer
          )

          transformed_params = service.send(:updater_service_params)

          expect(transformed_params[:clear_discount]).to eq(false)
        end
      end

      context "when an invalid discount code is entered" do
        it "does not include offer_code in params" do
          params_with_discount = offer_code_params.deep_merge(
            purchase: { discount_code: "NONEXISTENT" }
          )

          service = described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: params_with_discount,
            buyer: buyer
          )

          transformed_params = service.send(:updater_service_params)

          expect(transformed_params).not_to have_key(:offer_code)
        end
      end
    end

    # Integration tests - verify error handling works correctly
    # Success cases are covered by UpdaterService specs; we just verify delegation
    describe "integration behavior" do
      context "when subscription is cancelled by seller" do
        let!(:subscription) do
          create_subscription_for_product(
            product: product,
            purchaser: buyer,
            email: email,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: false,
            cancelled_by_admin: true,
            deactivated_at: 1.day.ago
          )
        end

        it "returns an error" do
          result = described_class.new(
            subscription: subscription,
            product: product,
            params: base_params,
            buyer: buyer
          ).perform

          expect(result[:success]).to be false
          expect(result[:error_message]).to eq("This subscription cannot be restarted.")
        end
      end

      context "when product is deleted" do
        let!(:subscription) do
          create_subscription_for_product(
            product: product,
            purchaser: buyer,
            email: email,
            cancelled_at: 1.day.ago,
            cancelled_by_buyer: true,
            deactivated_at: 1.day.ago
          )
        end

        before do
          product.update!(deleted_at: 1.hour.ago)
        end

        it "returns an error" do
          result = described_class.new(
            subscription: subscription,
            product: product,
            params: base_params,
            buyer: buyer
          ).perform

          expect(result[:success]).to be false
          expect(result[:error_message]).to eq("This subscription cannot be restarted.")
        end
      end
    end
  end
end
