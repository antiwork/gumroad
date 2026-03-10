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

      it "passes the original purchase quantity to UpdaterService" do
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

    describe "offer code discount synchronization" do
      let(:expensive_product) { create(:membership_product, user: seller, price_cents: 10_00) }
      let(:offer_code) { create(:offer_code, amount_cents: nil, amount_percentage: 25, products: [expensive_product], user: seller) }

      let!(:subscription) do
        sub = create_subscription_for_product(
          product: expensive_product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
        original_purchase = sub.original_purchase
        original_purchase.offer_code = offer_code
        pre_discount_price = original_purchase.minimum_paid_price_cents_per_unit_before_discount
        discounted_price = (pre_discount_price * 0.75).round
        original_purchase.update!(displayed_price_cents: discounted_price)
        original_purchase.create_purchase_offer_code_discount!(
          offer_code: offer_code,
          offer_code_amount: 25,
          offer_code_is_percent: true,
          pre_discount_minimum_price_cents: pre_discount_price
        )
        sub
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

      context "when offer code percentage has changed" do
        before do
          offer_code.update!(amount_percentage: 50)
        end

        it "syncs the purchase_offer_code_discount to the current offer code values" do
          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

          described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          ).perform

          discount = subscription.original_purchase.purchase_offer_code_discount.reload
          expect(discount.offer_code_amount).to eq(50)
          expect(discount.offer_code_is_percent).to be true
        end

        it "updates displayed_price_cents on the original purchase to reflect the current discount" do
          original_purchase = subscription.original_purchase
          pre_discount_price = original_purchase.minimum_paid_price_cents_per_unit_before_discount
          expected_price = (pre_discount_price * 0.50).round

          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

          described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          ).perform

          expect(original_purchase.reload.displayed_price_cents).to eq(expected_price)
        end

        it "rolls back offer code discount changes when UpdaterService fails" do
          original_purchase = subscription.original_purchase
          original_displayed_price = original_purchase.displayed_price_cents

          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform).and_return({ success: false, error_message: "Something went wrong" })

          described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          ).perform

          discount = original_purchase.purchase_offer_code_discount.reload
          expect(discount.offer_code_amount).to eq(25)
          expect(original_purchase.reload.displayed_price_cents).to eq(original_displayed_price)
        end

        it "reverts the sync when 3DS confirmation is required" do
          original_purchase = subscription.original_purchase
          original_displayed_price = original_purchase.displayed_price_cents

          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform).and_return({
                                                                   success: true,
                                                                   requires_card_action: true,
                                                                   client_secret: "pi_secret_123"
                                                                 })

          described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          ).perform

          discount = original_purchase.purchase_offer_code_discount.reload
          expect(discount.offer_code_amount).to eq(25)
          expect(discount.offer_code_is_percent).to be true
          expect(original_purchase.reload.displayed_price_cents).to eq(original_displayed_price)
        end

        it "reverts the snapshotted purchase when original_purchase changes during 3DS" do
          old_purchase = subscription.original_purchase
          old_displayed_price = old_purchase.displayed_price_cents

          # Create a different purchase to simulate UpdaterService swapping original_purchase
          different_purchase = create(:free_purchase,
                                      link: expensive_product,
                                      purchaser: buyer,
                                      email: email,
                                      subscription: subscription
          )
          different_purchase.update_columns(displayed_price_cents: 20_00)

          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform) do
            # Simulate UpdaterService replacing the original purchase mid-flow.
            # After this, subscription.original_purchase returns the new purchase.
            allow(subscription).to receive(:original_purchase).and_return(different_purchase)
            { success: true, requires_card_action: true, client_secret: "pi_secret_123" }
          end

          described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          ).perform

          # The old (snapshotted) purchase should be reverted to pre-sync values
          old_discount = old_purchase.purchase_offer_code_discount.reload
          expect(old_discount.offer_code_amount).to eq(25)
          expect(old_discount.offer_code_is_percent).to be true
          expect(old_purchase.reload.displayed_price_cents).to eq(old_displayed_price)

          # The new original_purchase should remain untouched
          expect(different_purchase.reload.displayed_price_cents).to eq(20_00)
        end
      end

      context "when offer code duration has changed" do
        before do
          offer_code.update!(duration_in_months: 3)
          subscription.original_purchase.purchase_offer_code_discount.update!(duration_in_months: 1)
        end

        it "syncs the duration_in_billing_cycles to the current offer code value" do
          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

          described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          ).perform

          discount = subscription.original_purchase.purchase_offer_code_discount.reload
          expect(discount.duration_in_billing_cycles).to eq(3)
        end

        it "rolls back duration changes when UpdaterService fails" do
          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform).and_return({ success: false, error_message: "Something went wrong" })

          described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          ).perform

          discount = subscription.original_purchase.purchase_offer_code_discount.reload
          expect(discount.duration_in_billing_cycles).to eq(1)
        end
      end

      context "when offer code percentage has not changed" do
        it "does not modify the purchase_offer_code_discount" do
          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

          expect do
            described_class.new(
              subscription: subscription,
              product: expensive_product,
              params: offer_code_params,
              buyer: buyer
            ).perform
          end.not_to change { subscription.original_purchase.purchase_offer_code_discount.reload.offer_code_amount }
        end
      end

      context "when offer code type changes from percent to fixed amount" do
        before do
          offer_code.update!(amount_percentage: nil, amount_cents: 2_00, currency_type: expensive_product.price_currency_type)
        end

        it "syncs the discount type and amount" do
          updater_service = instance_double(Subscription::UpdaterService)
          allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
          allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

          described_class.new(
            subscription: subscription,
            product: expensive_product,
            params: offer_code_params,
            buyer: buyer
          ).perform

          discount = subscription.original_purchase.purchase_offer_code_discount.reload
          expect(discount.offer_code_amount).to eq(2_00)
          expect(discount.offer_code_is_percent).to be false
        end
      end
    end

    describe ".sync_offer_code_discount!" do
      let(:expensive_product) { create(:membership_product, user: seller, price_cents: 10_00) }
      let(:offer_code) { create(:offer_code, amount_cents: nil, amount_percentage: 25, duration_in_months: 1, products: [expensive_product], user: seller) }

      let!(:subscription) do
        sub = create_subscription_for_product(
          product: expensive_product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
        original_purchase = sub.original_purchase
        original_purchase.offer_code = offer_code
        pre_discount_price = original_purchase.minimum_paid_price_cents_per_unit_before_discount
        discounted_price = (pre_discount_price * 0.75).round
        original_purchase.update!(displayed_price_cents: discounted_price)
        original_purchase.create_purchase_offer_code_discount!(
          offer_code: offer_code,
          offer_code_amount: 25,
          offer_code_is_percent: true,
          pre_discount_minimum_price_cents: pre_discount_price,
          duration_in_months: 1
        )
        sub
      end

      it "syncs percentage, type, and duration from the current offer code" do
        offer_code.update!(amount_percentage: 50, duration_in_months: 3)

        described_class.sync_offer_code_discount!(subscription)

        discount = subscription.original_purchase.purchase_offer_code_discount.reload
        expect(discount.offer_code_amount).to eq(50)
        expect(discount.offer_code_is_percent).to be true
        expect(discount.duration_in_billing_cycles).to eq(3)
      end

      it "is a no-op when nothing has changed" do
        expect do
          described_class.sync_offer_code_discount!(subscription)
        end.not_to change { subscription.original_purchase.purchase_offer_code_discount.reload.updated_at }
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
