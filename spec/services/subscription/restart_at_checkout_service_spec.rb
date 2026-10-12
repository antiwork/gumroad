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
        submitted_price = product.price_cents + 2_00
        offer_code = create(:offer_code, user: seller, products: [product])
        allocation = { offer_code_id: offer_code.id, amount_cents: 5_00 }
        checkout_params = base_params.merge(
          submitted_pre_discount_price_cents: submitted_price,
          once_per_cart_discount_allocation: allocation
        )
        service = described_class.new(
          subscription: subscription,
          product: product,
          params: checkout_params,
          buyer: buyer
        )

        # Use send to test private method
        transformed_params = service.send(:updater_service_params)

        expect(transformed_params[:perceived_price_cents]).to eq(product.price_cents)
        expect(transformed_params[:perceived_upgrade_price_cents]).to eq(product.price_cents)
        expect(transformed_params[:price_range]).to eq(product.price_cents)
        expect(transformed_params[:price_id]).to eq(product.prices.alive.first.external_id)
        expect(transformed_params[:use_existing_card]).to be true
        expect(transformed_params[:submitted_pre_discount_price_cents]).to eq(submitted_price)
        expect(transformed_params[:once_per_cart_discount_allocation].to_h.symbolize_keys).to eq(allocation)
        expect(transformed_params[:offer_code]).to eq(offer_code)
      end

      it "passes checkout contact information to the updater" do
        checkout_params = base_params.deep_merge(
          purchase: {
            full_name: "Buyer Name",
            street_address: "123 Main St",
            country: "US",
            state: "CA",
            zip_code: "94107",
            city: "San Francisco",
          }
        )

        transformed_params = described_class.new(
          subscription:,
          product:,
          params: checkout_params,
          buyer:
        ).send(:updater_service_params)

        expect(transformed_params[:contact_info]).to eq(
          email:,
          full_name: "Buyer Name",
          street_address: "123 Main St",
          country: "US",
          state: "CA",
          zip_code: "94107",
          city: "San Francisco"
        )
      end

      it "uses the buyer identity when defaulting the perceived restart price" do
        params_without_perceived_price = base_params.deep_dup
        params_without_perceived_price[:purchase].delete(:perceived_price_cents)

        expect(subscription).to receive(:current_subscription_price_cents).with(authenticated_offer_code_buyer: nil).and_return(10_00)
        guest_params = described_class.new(
          subscription: subscription,
          product: product,
          params: params_without_perceived_price,
          buyer: nil
        ).send(:updater_service_params)
        expect(subscription).to receive(:current_subscription_price_cents).with(authenticated_offer_code_buyer: buyer).and_return(9_00)
        buyer_params = described_class.new(
          subscription: subscription,
          product: product,
          params: params_without_perceived_price,
          buyer: buyer
        ).send(:updater_service_params)

        expect(guest_params[:perceived_price_cents]).to eq(10_00)
        expect(buyer_params[:perceived_price_cents]).to eq(9_00)
      end

      it "treats submitted checkout payment data as a new card" do
        params_with_stripe = ActionController::Parameters.new(
          base_params.deep_stringify_keys.merge(
            "stripe_payment_method_id" => "pm_123",
            "stripe_customer_id" => "cus_123",
            "stripe_setup_intent_id" => "seti_123"
          )
        )
        params_with_stripe.permit!

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
        expect(transformed_params[:use_existing_card]).to be false
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

    describe "PWYW subscription restart with discount change" do
      let(:pwyw_product) { create(:membership_product, user: seller, price_cents: 0, customizable_price: true) }
      let(:original_offer_code) { create(:offer_code, code: "original85", amount_cents: nil, amount_percentage: 85, products: [pwyw_product], user: seller) }
      let(:new_offer_code) { create(:offer_code, code: "new80", amount_cents: nil, amount_percentage: 80, products: [pwyw_product], user: seller) }

      let!(:subscription) do
        sub = create(:subscription, link: pwyw_product, user: buyer)
        purchase = create(:purchase,
                          link: pwyw_product,
                          purchaser: buyer,
                          email: email,
                          subscription: sub,
                          is_original_subscription_purchase: true,
                          price_cents: 500_00,
                          displayed_price_cents: 500_00,
                          perceived_price_cents: 500_00,
                          offer_code: original_offer_code,
                          variant_attributes: pwyw_product.tiers.to_a)
        purchase.create_purchase_offer_code_discount!(
          offer_code: original_offer_code,
          offer_code_amount: 85,
          offer_code_is_percent: true,
          pre_discount_minimum_price_cents: purchase.minimum_paid_price_cents_per_unit_before_discount
        )
        sub.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)
        sub
      end

      it "passes price_range so PWYW price is preserved when discount changes" do
        perceived_price = 500_00
        params = {
          purchase: {
            email: email,
            perceived_price_cents: perceived_price,
            browser_guid: browser_guid,
            discount_code: new_offer_code.code
          },
          price_id: pwyw_product.prices.alive.first.external_id,
          remote_ip: "127.0.0.1"
        }

        service = described_class.new(
          subscription: subscription,
          product: pwyw_product,
          params: params,
          buyer: buyer
        )

        transformed_params = service.send(:updater_service_params)

        expect(transformed_params[:price_range]).to eq(perceived_price)
        expect(transformed_params[:perceived_price_cents]).to eq(perceived_price)
        expect(transformed_params[:offer_code]).to eq(new_offer_code)
      end
    end

    describe "Indian card mandate still pending" do
      let(:merchant_account) do
        create(
          :merchant_account,
          user: nil,
          charge_processor_id: StripeChargeProcessor.charge_processor_id,
          charge_processor_merchant_id: nil
        )
      end
      let(:credit_card) do
        create(:indian_stripe_credit_card)
      end
      let(:product) { create(:subscription_product_with_versions, user: seller) }
      let!(:subscription) do
        subscription = create(:subscription, link: product, user: buyer, credit_card: credit_card, stripe_mandate_id: "mandate_pending")
        travel_to(1.month.ago) do
          create(:purchase,
                 is_original_subscription_purchase: true,
                 link: product,
                 subscription: subscription,
                 purchaser: buyer,
                 email: email,
                 price_cents: product.default_price_cents,
                 credit_card: credit_card,
                 variant_attributes: [product.variants.first])
        end
        subscription.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)
        subscription
      end
      let(:base_params) do
        {
          purchase: { email: email, perceived_price_cents: product.default_price_cents, browser_guid: browser_guid },
          price_id: subscription.price.external_id,
          variants: [product.variants.first.external_id],
          remote_ip: "127.0.0.1"
        }
      end
      let(:mandate_status) { "pending" }

      before do
        allow(MerchantAccount).to receive(:gumroad)
          .with(StripeChargeProcessor.charge_processor_id)
          .and_return(merchant_account)
        Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
        allow(ChargeProcessor).to receive(:get_mandate) do
          Stripe::Mandate.construct_from(id: "mandate_pending", status: mandate_status, payment_method: "pm_pending")
        end
        allow(subscription).to receive(:send_restart_notifications!)
      end

      after do
        Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
      end

      def restart_overdue_subscription
        travel_to(2.months.from_now) do
          described_class.new(subscription: subscription, product: product, params: base_params, buyer: buyer).perform
        end
      end

      let(:pending_message) { Subscription::UpdaterService::MANDATE_STILL_PENDING_RESTART_MESSAGE }

      it "leaves the membership ended and uncharged while the saved card's mandate is pending" do
        expect(subscription).not_to receive(:charge!)

        result = restart_overdue_subscription

        expect(result).to eq(success: false, error_message: pending_message)
        expect(subscription.reload).not_to be_alive
        expect(subscription).to be_indian_card_mandate_restart_held
        expect(subscription.purchases.not_is_original_subscription_purchase.count).to eq(0)
        expect(RecurringChargeWorker.jobs.size).to eq(0)
        expect(CompleteIndianCardMandateJob.jobs.size).to eq(1)
      end

      it "gives the same answer to a repeated submission and keeps the one completion chain the first submission enqueued" do
        expect(subscription).not_to receive(:charge!)

        2.times { expect(restart_overdue_subscription).to include(success: false, error_message: pending_message) }

        expect(subscription.reload).not_to be_alive
        expect(subscription.stripe_mandate_id).to eq("mandate_pending")
        expect(subscription).to be_indian_card_mandate_restart_held
        expect(CompleteIndianCardMandateJob.jobs.map { _1["args"].first(2) }).to eq([[subscription.id, 0]])
        generation = CompleteIndianCardMandateJob.jobs.first["args"].last
        expect(CompleteIndianCardMandateJob.superseded?(subscription.id, generation)).to be(false)
      end

      it "restarts and charges when a later submission finds the mandate active" do
        restart_overdue_subscription
        allow(ChargeProcessor).to receive(:get_mandate).and_return(
          Stripe::Mandate.construct_from(id: "mandate_pending", status: "active", payment_method: "pm_pending")
        )
        renewal = instance_double(Purchase, successful?: true, test_successful?: false, errors: ActiveModel::Errors.new(nil), error_code: nil, external_id: "renewal_external_id")
        expect(subscription).to receive(:charge!).once.and_return(renewal)

        result = restart_overdue_subscription

        expect(result).to include(success: true, restarted_subscription: true)
        expect(subscription.reload).to be_alive
        expect(subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
        expect(subscription).not_to be_indian_card_mandate_restart_held
      end

      context "when the accepted restart is completed later and charged by a plain job" do
        let(:product) { create(:subscription_product_with_versions, user: seller, price_cents: 10_00) }
        let(:quantity) { 2 }
        let(:full_price_cents) { product.default_price_cents * quantity }
        let(:discounted_price_cents) { full_price_cents / 2 }
        let!(:existing_customer_offer_code) do
          create(:offer_code, :for_existing_customers, products: [product], user: seller, amount_cents: nil, amount_percentage: 50)
        end
        let(:charged) { [] }

        before do
          subscription.original_purchase.update_columns(quantity:, price_cents: full_price_cents, displayed_price_cents: full_price_cents)
          # Records the purchase `charge!` built, which is what the charge would be taken for.
          allow_any_instance_of(Subscription).to receive(:process_purchase!) do |_subscription, purchase, *|
            charged << [purchase.perceived_price_cents, purchase.quantity, purchase.offer_code&.id]
          end
        end

        def accept_pending_restart(restart_buyer:, perceived_price_cents:)
          travel_to(2.months.from_now) do
            described_class.new(
              subscription: subscription,
              product: product,
              params: base_params.deep_merge(purchase: { perceived_price_cents: }),
              buyer: restart_buyer
            ).perform
          end
        end

        def complete_held_restart_and_run_charge_job
          allow(ChargeProcessor).to receive(:get_mandate).and_return(
            Stripe::Mandate.construct_from(id: "mandate_pending", status: "active", payment_method: "pm_pending")
          )
          travel_to(2.months.from_now) do
            CompleteIndianCardMandateJob.drain
            expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
            RecurringChargeWorker.drain
          end
        end

        it "records an authenticated buyer's id, price and quantity, then charges exactly that price and quantity" do
          result = accept_pending_restart(restart_buyer: buyer, perceived_price_cents: discounted_price_cents)

          expect(result).to eq(success: false, error_message: pending_message)
          subscription.reload
          expect(subscription).to be_indian_card_mandate_restart_held
          expect(subscription.indian_card_mandate_restart_buyer_id).to eq(buyer.id)
          expect(subscription.indian_card_mandate_restart_price_cents).to eq(discounted_price_cents)
          expect(subscription.indian_card_mandate_restart_quantity).to eq(quantity)
          expect(subscription).not_to be_indian_card_mandate_restart_charge_pricing_pending

          complete_held_restart_and_run_charge_job

          subscription.reload
          expect(subscription).to be_alive
          expect(subscription).to be_indian_card_mandate_restart_charge_pricing_pending
          expect(subscription.indian_card_mandate_restart_buyer_id).to eq(buyer.id)
          expect(charged).to eq([[discounted_price_cents, quantity, existing_customer_offer_code.id]])
        end

        it "records a signed-out buyer's nil id with the guest price and quantity, then charges exactly that" do
          result = accept_pending_restart(restart_buyer: nil, perceived_price_cents: full_price_cents)

          expect(result).to eq(success: false, error_message: pending_message)
          subscription.reload
          expect(subscription).to be_indian_card_mandate_restart_held
          expect(subscription.indian_card_mandate_restart_buyer_id).to be_nil
          expect(subscription.indian_card_mandate_restart_price_cents).to eq(full_price_cents)
          expect(subscription.indian_card_mandate_restart_quantity).to eq(quantity)
          expect(subscription).not_to be_indian_card_mandate_restart_charge_pricing_pending

          complete_held_restart_and_run_charge_job

          subscription.reload
          expect(subscription).to be_alive
          expect(subscription).to be_indian_card_mandate_restart_charge_pricing_pending
          expect(subscription.indian_card_mandate_restart_buyer_id).to be_nil
          expect(charged).to eq([[full_price_cents, quantity, nil]])
        end

        it "refuses an authenticated buyer's submission priced as signed-out, so the buyer is what prices the hold" do
          result = accept_pending_restart(restart_buyer: buyer, perceived_price_cents: full_price_cents)

          expect(result).to eq(success: false, error_message: "The price just changed! Refresh the page for the updated price.")
          expect(subscription.reload).not_to be_indian_card_mandate_restart_held
        end
      end

      context "when the mandate is inactive" do
        let(:mandate_status) { "inactive" }

        it "refuses the restart and leaves the subscription ended" do
          result = restart_overdue_subscription

          expect(result[:success]).to be(false)
          expect(result[:error_message]).to eq("We could not verify this card for recurring payments. Please update the payment method before you restart this subscription.")
          expect(subscription.reload).not_to be_alive
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

        it "returns a seller-cancelled error when no new payment method is being attached" do
          result = described_class.new(
            subscription: subscription,
            product: product,
            params: base_params,
            buyer: buyer
          ).perform

          expect(result[:success]).to be false
          expect(result[:error_message]).to eq("This membership was cancelled by the creator. To continue, please subscribe again from the product page.")
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

        it "returns a product-unavailable error" do
          result = described_class.new(
            subscription: subscription,
            product: product,
            params: base_params,
            buyer: buyer
          ).perform

          expect(result[:success]).to be false
          expect(result[:error_message]).to eq("This product is no longer available, so this membership can't be restarted.")
        end
      end
    end
  end
end
