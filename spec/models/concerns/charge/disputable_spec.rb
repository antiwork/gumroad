# frozen_string_literal: true

require "spec_helper"

describe Charge::Disputable, :vcr do
  let(:stripe_purchase) do
    create(:purchase,
           charge_processor_id: StripeChargeProcessor.charge_processor_id,
           stripe_transaction_id: "ch_12345",
           total_transaction_cents: 10_00,
           succeeded_at: Date.new(2024, 2, 27))
  end

  let(:paypal_purchase) do
    create(:purchase,
           charge_processor_id: PaypalChargeProcessor.charge_processor_id,
           stripe_transaction_id: "pp_12345",
           total_transaction_cents: 20_00,
           succeeded_at: Date.new(2024, 2, 28))
  end

  let(:braintree_purchase) do
    create(:purchase,
           charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
           stripe_transaction_id: "bt_12345",
           total_transaction_cents: 30_00,
           succeeded_at: Date.new(2024, 2, 29))
  end

  let(:stripe_charge) do
    create(:charge,
           processor: StripeChargeProcessor.charge_processor_id,
           processor_transaction_id: "ch_12345",
           amount_cents: 10_00)
  end

  let(:paypal_charge) do
    create(:charge,
           processor: PaypalChargeProcessor.charge_processor_id,
           processor_transaction_id: "pp_12345",
           amount_cents: 20_00)
  end

  let(:braintree_charge) do
    create(:charge,
           processor: BraintreeChargeProcessor.charge_processor_id,
           processor_transaction_id: "bt_12345",
           amount_cents: 30_00)
  end

  describe "#charge_processor" do
    it "returns the charge processor id of the purchase" do
      expect(stripe_purchase.charge_processor).to eq("stripe")
      expect(paypal_purchase.charge_processor).to eq("paypal")
      expect(braintree_purchase.charge_processor).to eq("braintree")
    end

    it "returns the processor of the charge" do
      expect(stripe_charge.charge_processor).to eq("stripe")
      expect(paypal_charge.charge_processor).to eq("paypal")
      expect(braintree_charge.charge_processor).to eq("braintree")
    end
  end

  describe "#charge_processor_transaction_id" do
    it "returns the Stripe/PayPal transaction id of the purchase" do
      expect(stripe_purchase.charge_processor_transaction_id).to eq("ch_12345")
      expect(paypal_purchase.charge_processor_transaction_id).to eq("pp_12345")
      expect(braintree_purchase.charge_processor_transaction_id).to eq("bt_12345")
    end

    it "returns the Stripe/PayPal transaction id of the charge" do
      expect(stripe_charge.charge_processor_transaction_id).to eq("ch_12345")
      expect(paypal_charge.charge_processor_transaction_id).to eq("pp_12345")
      expect(braintree_charge.charge_processor_transaction_id).to eq("bt_12345")
    end
  end

  describe "#purchase_for_dispute_evidence" do
    it "returns the purchase object itself" do
      expect(stripe_purchase.purchase_for_dispute_evidence).to eq(stripe_purchase)
      expect(paypal_purchase.purchase_for_dispute_evidence).to eq(paypal_purchase)
      expect(braintree_purchase.purchase_for_dispute_evidence).to eq(braintree_purchase)
    end

    describe "for a Charge" do
      let!(:charge) { create(:charge) }

      context "includes a subscription purchase with a refund policy" do
        before do
          membership_product = create(:membership_product)
          @membership_purchase_with_refund_policy = create(:membership_purchase, total_transaction_cents: 10_00, link: membership_product)
          @membership_purchase_with_refund_policy.create_purchase_refund_policy!(title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30], max_refund_period_in_days: 30)
          product = create(:product)
          regular_purchase = create(:purchase, total_transaction_cents: 150_00, link: product)
          regular_purchase.create_purchase_refund_policy!(title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30], max_refund_period_in_days: 30)

          charge.purchases << create(:membership_purchase, total_transaction_cents: 100_00)
          charge.purchases << @membership_purchase_with_refund_policy
          charge.purchases << regular_purchase
        end

        it "returns it" do
          expect(charge.purchase_for_dispute_evidence).to eq @membership_purchase_with_refund_policy
        end

        it "returns the purchase with highest total amount if there are multiple" do
          membership_product = create(:membership_product)
          membership_purchase_with_refund_policy = create(:membership_purchase, total_transaction_cents: 15_00, link: membership_product)
          membership_purchase_with_refund_policy.create_purchase_refund_policy!(title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30], max_refund_period_in_days: 30)
          charge.purchases << membership_purchase_with_refund_policy

          expect(charge.purchase_for_dispute_evidence).to eq membership_purchase_with_refund_policy
        end
      end

      context "includes a regular purchase with a refund policy" do
        before do
          product = create(:product)
          @regular_purchase_with_refund_policy = create(:purchase, total_transaction_cents: 10_00, link: product)
          @regular_purchase_with_refund_policy.create_purchase_refund_policy!(title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30], max_refund_period_in_days: 30)

          charge.purchases << create(:purchase, total_transaction_cents: 100_00, link: product)
          charge.purchases << @regular_purchase_with_refund_policy
        end

        it "returns it if dispute reason is not subscription canceled" do
          expect(charge.purchase_for_dispute_evidence).to eq @regular_purchase_with_refund_policy
        end

        it "returns the purchase with highest total amount if there are multiple" do
          product = create(:product)
          regular_purchase_with_refund_policy = create(:purchase, total_transaction_cents: 15_00, link: product)
          regular_purchase_with_refund_policy.create_purchase_refund_policy!(title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30], max_refund_period_in_days: 30)
          charge.purchases << regular_purchase_with_refund_policy

          expect(charge.purchase_for_dispute_evidence).to eq regular_purchase_with_refund_policy
        end
      end

      context "includes a subscription purchase without a refund policy" do
        before do
          create(:dispute_on_charge, charge:, reason: Dispute::REASON_SUBSCRIPTION_CANCELED)
          @membership_purchase = create(:membership_purchase, total_transaction_cents: 10_00)
          charge.purchases << @membership_purchase
          regular_purchase_with_refund_policy = create(:purchase, total_transaction_cents: 100_00)
          regular_purchase_with_refund_policy.create_purchase_refund_policy!(title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30], max_refund_period_in_days: 30)
          charge.purchases << regular_purchase_with_refund_policy
        end

        it "returns it if dispute reason is subscription canceled" do
          expect(charge.purchase_for_dispute_evidence).to eq @membership_purchase
        end

        it "returns the purchase with highest total amount if there are multiple" do
          membership_purchase = create(:membership_purchase, total_transaction_cents: 15_00)
          charge.purchases << membership_purchase

          expect(charge.purchase_for_dispute_evidence).to eq membership_purchase
        end
      end

      context "includes a regular purchase without a refund policy" do
        before do
          @regular_purchase = create(:purchase, total_transaction_cents: 15_00)
          charge.purchases << @regular_purchase
          charge.purchases << create(:purchase, total_transaction_cents: 10_00)
        end

        it "returns the purchase with highest total amount if there are multiple" do
          expect(charge.purchase_for_dispute_evidence).to eq @regular_purchase
        end
      end
    end
  end

  describe "#first_product_without_refund_policy" do
    it "returns the product associated with the purchase object" do
      expect(stripe_purchase.first_product_without_refund_policy).to eq(stripe_purchase.link)
      expect(paypal_purchase.first_product_without_refund_policy).to eq(paypal_purchase.link)
      expect(braintree_purchase.first_product_without_refund_policy).to eq(braintree_purchase.link)
    end

    describe "for a Charge" do
      it "returns a purchase that does not have a refund policy" do
        charge = create(:charge)

        purchase_with_refund_policy = create(:purchase)
        create(:product_refund_policy, seller: purchase_with_refund_policy.seller, product: purchase_with_refund_policy.link)
        purchase_with_refund_policy.link.update!(product_refund_policy_enabled: true)

        purchase_without_refund_policy = create(:purchase, link: create(:product, user: purchase_with_refund_policy.seller))

        charge.purchases << purchase_without_refund_policy
        charge.purchases << purchase_with_refund_policy

        expect(charge.first_product_without_refund_policy).to eq(purchase_without_refund_policy.link)
      end
    end
  end

  describe "#disputed_amount_cents" do
    it "returns the total transaction cents of the purchase" do
      expect(stripe_purchase.disputed_amount_cents).to eq(10_00)
      expect(paypal_purchase.disputed_amount_cents).to eq(20_00)
      expect(braintree_purchase.disputed_amount_cents).to eq(30_00)
    end

    it "returns the amount_cents of the Charge" do
      expect(stripe_charge.disputed_amount_cents).to eq(10_00)
      expect(paypal_charge.disputed_amount_cents).to eq(20_00)
      expect(braintree_charge.disputed_amount_cents).to eq(30_00)
    end
  end

  describe "#formatted_disputed_amount" do
    it "returns the total transaction cents of the purchase" do
      expect(stripe_purchase.formatted_disputed_amount).to eq("$10")
      expect(paypal_purchase.formatted_disputed_amount).to eq("$20")
      expect(braintree_purchase.formatted_disputed_amount).to eq("$30")
    end

    it "returns the amount_cents of the Charge" do
      expect(stripe_charge.formatted_disputed_amount).to eq("$10")
      expect(paypal_charge.formatted_disputed_amount).to eq("$20")
      expect(braintree_charge.formatted_disputed_amount).to eq("$30")
    end
  end

  describe "#customer_email" do
    it "returns the email of the Purchase" do
      expect(stripe_purchase.customer_email).to eq(stripe_purchase.email)
      expect(paypal_purchase.customer_email).to eq(paypal_purchase.email)
      expect(braintree_purchase.customer_email).to eq(braintree_purchase.email)
    end

    it "returns the email of the Purchase selected for dispute evidence for a Charge" do
      stripe_charge.purchases << stripe_purchase
      expect(stripe_charge.customer_email).to eq(stripe_purchase.email)

      paypal_charge.purchases << paypal_purchase
      expect(paypal_charge.customer_email).to eq(paypal_purchase.email)

      braintree_charge.purchases << braintree_purchase
      expect(braintree_charge.customer_email).to eq(braintree_purchase.email)
    end
  end

  describe "#disputed_purchases" do
    it "returns an array containing the purchase object" do
      expect(stripe_purchase.disputed_purchases).to eq([stripe_purchase])
      expect(paypal_purchase.disputed_purchases).to eq([paypal_purchase])
      expect(braintree_purchase.disputed_purchases).to eq([braintree_purchase])
    end
  end

  describe "#dispute_balance_date" do
    it "returns the succeeded date of the purchase" do
      expect(stripe_purchase.dispute_balance_date).to eq(Date.new(2024, 2, 27))
      expect(paypal_purchase.dispute_balance_date).to eq(Date.new(2024, 2, 28))
      expect(braintree_purchase.dispute_balance_date).to eq(Date.new(2024, 2, 29))
    end
  end

  describe "handles dispute events" do
    describe "dispute formalized" do
      let(:initial_balance) { 200 }
      let(:seller) { create(:user, unpaid_balance_cents: initial_balance) }
      let(:product) { create(:product, user: seller) }
      let!(:purchase) do
        create(:purchase, link: product, seller: product.user, stripe_transaction_id: "ch_zitkxbhds3zqlt", price_cents: 100,
                          total_transaction_cents: 100, fee_cents: 30)
      end
      let(:event) { build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt") }

      before do
        sample_image = File.read(Rails.root.join("spec", "support", "fixtures", "test-small.jpg"))
        allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform).with(purchase).and_return(sample_image)
      end

      it "doesn't deduct Gumroad fees from the seller's balance" do
        Purchase.handle_charge_event(event)
        purchase.reload
        seller.reload
        expect(seller.unpaid_balance_cents).to eq initial_balance - purchase.payment_cents
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
      end

      context "when the product is a subscription" do
        let(:product) { create(:subscription_product, user: seller) }
        let!(:purchase) do
          subscription = create(:subscription, link: product, cancelled_at: nil)
          purchase = create(:purchase, link: product, is_original_subscription_purchase: true, subscription:, stripe_transaction_id: "ch_zitkxbhds3zqlt")
          purchase.update(is_original_subscription_purchase: true, subscription:)
          purchase
        end

        it "cancels the subscription if the product is a subscription" do
          Purchase.handle_charge_event(event)
          purchase.reload
          expect(purchase.subscription.cancelled_at).to_not be(nil)
          expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
        end
      end

      it "sends emails to admin, creator, and customer" do
        mail = double("mail")
        expect(mail).to receive(:deliver_later).exactly(3).times
        expect(AdminMailer).to receive(:chargeback_notify).and_return(mail)
        expect(ContactingCreatorMailer).to receive(:chargeback_notice).and_return(mail)
        expect(CustomerLowPriorityMailer).to receive(:chargeback_notice_to_customer).and_return(mail)
        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
      end

      it "enqueues the post to ping job for 'dispute' resource" do
        Purchase.handle_charge_event(event)
        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, nil, ResourceSubscription::DISPUTE_RESOURCE_NAME)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
      end

      it "calls pause_payouts_for_seller_based_on_chargeback_rate! for each purchase" do
        expect_any_instance_of(Purchase).to receive(:pause_payouts_for_seller_based_on_chargeback_rate!)
        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
      end

      describe "purchase involves an affiliate" do
        let(:merchant_account) { create(:merchant_account, user: seller) }
        let(:affiliate_user) { create(:affiliate_user) }
        let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 2000, products: [product]) }
        let(:purchase) do
          issued_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100)
          settled_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110)
          gumroad_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30)
          merchant_account_gross_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110)
          merchant_account_net_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 80)
          create(
              :purchase_with_balance,
              link: product, seller:, stripe_transaction_id: "ch_zitkxbhds3zqlt", merchant_account:,
              total_transaction_cents: 100, fee_cents: 30,
              affiliate: direct_affiliate,
              flow_of_funds: FlowOfFunds.new(
                  issued_amount:,
                  settled_amount:,
                  gumroad_amount:,
                  merchant_account_gross_amount:,
                  merchant_account_net_amount:
                  )
          )
        end
        let(:event_flow_of_funds) do
          issued_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: -100)
          settled_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -110)
          gumroad_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: -30)
          merchant_account_gross_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -110)
          merchant_account_net_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -80)
          FlowOfFunds.new(
              issued_amount:,
              settled_amount:,
              gumroad_amount:,
              merchant_account_gross_amount:,
              merchant_account_net_amount:
              )
        end
        let(:event) { build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt", flow_of_funds: event_flow_of_funds) }

        before do
          purchase.reload

          expect(purchase.purchase_success_balance.amount_cents).to eq(6) # 100c - 20c (affiliate fees) + 19c (affiliate's share of Gumroad fee) - 10c (10% flat fee) -50c (fixed fee) - 3c (2.9% cc fee) - (30c fixed cc fee)
          expect(purchase.affiliate_credit.affiliate_credit_success_balance.amount_cents).to eq(1)
          allow_any_instance_of(Purchase).to receive(:fight_chargeback).and_return(true)

          Purchase.handle_charge_event(event)
          purchase.reload
        end

        it "updates the balance of the creator" do
          expect(purchase.purchase_chargeback_balance).to eq(purchase.purchase_success_balance)
          expect(purchase.purchase_chargeback_balance.amount_cents).to eq(0)
          expect(purchase.purchase_chargeback_balance.merchant_account_id).to eq(purchase.merchant_account_id)
          expect(purchase.purchase_chargeback_balance.merchant_account_id).to eq(purchase.purchase_success_balance.merchant_account_id)
        end

        it "updates the balance of the affiliate" do
          expect(purchase.affiliate_credit.affiliate_credit_chargeback_balance).to eq(purchase.affiliate_credit.affiliate_credit_success_balance)
          expect(purchase.affiliate_credit.affiliate_credit_chargeback_balance.amount_cents).to eq(0)
          expect(purchase.affiliate_credit.affiliate_credit_chargeback_balance.merchant_account_id).to eq(MerchantAccount.gumroad(purchase.charge_processor_id).id)
          expect(purchase.affiliate_credit.affiliate_credit_chargeback_balance.merchant_account_id).to eq(purchase.affiliate_credit.affiliate_credit_success_balance.merchant_account_id)
        end

        it "creates two balance transactions for the dispute formalized" do
          balance_transaction_1, balance_transaction_2 = BalanceTransaction.last(2)

          expect(balance_transaction_1.user).to eq(affiliate_user)
          expect(balance_transaction_1.merchant_account).to eq(purchase.affiliate_merchant_account)
          expect(balance_transaction_1.merchant_account).to eq(MerchantAccount.gumroad(purchase.charge_processor_id))
          expect(balance_transaction_1.refund).to eq(purchase.refunds.last)
          expect(balance_transaction_1.issued_amount_currency).to eq(Currency::USD)
          expect(balance_transaction_1.issued_amount_gross_cents).to eq(-1 * purchase.affiliate_credit_cents)
          expect(balance_transaction_1.issued_amount_net_cents).to eq(-1 * purchase.affiliate_credit_cents)
          expect(balance_transaction_1.holding_amount_currency).to eq(Currency::USD)
          expect(balance_transaction_1.holding_amount_gross_cents).to eq(-1 * purchase.affiliate_credit_cents)
          expect(balance_transaction_1.holding_amount_net_cents).to eq(-1 * purchase.affiliate_credit_cents)

          expect(balance_transaction_2.user).to eq(seller)
          expect(balance_transaction_2.merchant_account).to eq(purchase.merchant_account)
          expect(balance_transaction_2.merchant_account).to eq(merchant_account)
          expect(balance_transaction_2.refund).to eq(purchase.refunds.last)
          expect(balance_transaction_2.issued_amount_currency).to eq(Currency::USD)
          expect(balance_transaction_2.issued_amount_currency).to eq(event_flow_of_funds.issued_amount.currency)
          expect(balance_transaction_2.issued_amount_gross_cents).to eq(-1 * purchase.total_transaction_cents)
          expect(balance_transaction_2.issued_amount_gross_cents).to eq(event_flow_of_funds.issued_amount.cents)
          expect(balance_transaction_2.issued_amount_net_cents).to eq(-1 * (purchase.payment_cents - purchase.affiliate_credit_cents))
          expect(balance_transaction_2.holding_amount_currency).to eq(Currency::CAD)
          expect(balance_transaction_2.holding_amount_currency).to eq(event_flow_of_funds.merchant_account_gross_amount.currency)
          expect(balance_transaction_2.holding_amount_currency).to eq(event_flow_of_funds.merchant_account_net_amount.currency)
          expect(balance_transaction_2.holding_amount_gross_cents).to eq(event_flow_of_funds.merchant_account_gross_amount.cents)
          expect(balance_transaction_2.holding_amount_net_cents).to eq(event_flow_of_funds.merchant_account_net_amount.cents)
        end
      end

      describe "dispute object" do
        let!(:purchase) { create(:purchase, link: product, seller: product.user, stripe_transaction_id: "1", price_cents: 100, fee_cents: 30, total_transaction_cents: 100) }
        let(:event) { build(:charge_event_dispute_formalized, charge_id: "1", extras: { reason: "fraud", charge_processor_dispute_id: "2" }) }
        let(:frozen_time) { Time.zone.local(2015, 9, 8, 4, 57) }

        describe "dispute object already exists for purchase" do
          describe "existing disput object has formalized state" do
            before do
              Purchase.handle_charge_event(event)
              purchase.dispute.state = :formalized
              purchase.dispute.save!
              travel_to(frozen_time) do
                Purchase.handle_charge_event(event)
              end
            end

            it "does not decrement the seller's balance" do
              expect(purchase).to_not receive(:decrement_balance_for_refund_or_chargeback!)
            end
          end

          context "when the purchase has a dispute in created state" do
            before do
              Purchase.handle_charge_event(event)
              purchase.dispute.state = :created
              purchase.dispute.save!
            end

            it "does not create a new dispute" do
              travel_to(frozen_time) do
                Purchase.handle_charge_event(event)
              end
              expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
              expect(Dispute.where(purchase_id: purchase.id).count).to eq(1)
            end

            it "does not mark the dispute as formalized" do
              travel_to(frozen_time) do
                Purchase.handle_charge_event(event)
              end
              expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
              purchase.reload
              expect(purchase.dispute.state).to eq("formalized")
              expect(purchase.dispute.formalized_at).to eq(frozen_time)
            end
          end
        end

        context "when the purchase doesn't have a dispute" do
          before do
            Purchase.handle_charge_event(event)
          end

          it "creates a dispute" do
            expect(purchase.dispute).to be_a(Dispute)
          end

          it "sets the dispute's event creation time from the event" do
            expect(purchase.dispute.event_created_at.iso8601(6)).to eq(event.created_at.in_time_zone.iso8601(6))
          end

          it "sets the disputes reason from the event" do
            expect(purchase.dispute.reason).to eq(event.extras[:reason])
          end

          it "sets the disputes charge processor id from the purchase" do
            expect(purchase.dispute.charge_processor_id).to eq(purchase.charge_processor_id)
          end

          it "sets the dipsutes charge processor dispute id from the event" do
            expect(purchase.dispute.charge_processor_dispute_id).to eq(event.extras[:charge_processor_dispute_id])
          end

          it "marks the dispute as formalized" do
            expect(purchase.dispute.state).to eq("formalized")
            expect(purchase.dispute.formalized_at).not_to be(nil)
          end
        end
      end

      context "when the purchase is partially refunded" do
        before do
          purchase.refund_and_save!(product.user.id, amount_cents: 50)
        end

        it "deducts only remaining balance" do
          Purchase.handle_charge_event(event)
          expect(seller.reload.unpaid_balance_cents).to eq initial_balance - purchase.reload.payment_cents
        end
      end
    end

    describe "dispute closed" do
      describe "dispute won" do
        before do
          @initial_balance = 200
          @u = create(:user, unpaid_balance_cents: @initial_balance)
          @l = create(:product, user: @u)
          @p = create(:purchase, link: @l, seller: @l.user, stripe_transaction_id: "ch_zitkxbhds3zqlt", price_cents: 100,
                                 total_transaction_cents: 100, fee_cents: 30, chargeback_date: Date.today - 10)
          @e = build(:charge_event_dispute_won, charge_id: "ch_zitkxbhds3zqlt")
        end

        describe "purchase is partially refunded" do
          let(:refund_flow_of_funds) { FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -50) }

          before do
            unpaid_balance_before = @u.unpaid_balance_cents
            @p.refund_purchase!(refund_flow_of_funds, nil)
            @p.reload
            @difference_cents = unpaid_balance_before - @u.unpaid_balance_cents
          end

          it "credits only remaining balance" do
            Purchase.handle_charge_event(@e)
            @u.reload
            expect(Credit.last.user).to eq @p.seller
            expect(Credit.last.amount_cents).to eq 4
            expect(Credit.last.chargebacked_purchase_id).to eq @p.id
          end
        end

        it "credits the creator" do
          count = Credit.all.count

          Purchase.handle_charge_event(@e)
          expect(Credit.last.user).to eq @p.seller
          expect(Credit.last.amount_cents).to eq @p.payment_cents
          expect(Credit.last.chargebacked_purchase_id).to eq @p.id
          expect(Credit.all.count).to eq count + 1
        end

        it "emails the creator" do
          mail_double = double
          allow(mail_double).to receive(:deliver_later)
          expect(ContactingCreatorMailer).to receive(:chargeback_won).and_return(mail_double)
          expect(ContactingCreatorMailer).to_not receive(:credit_notification).with(@u.id, 100)
          Purchase.handle_charge_event(@e)
        end

        it "enqueues the post to ping job for 'dispute_won' resource" do
          Purchase.handle_charge_event(@e)
          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(@p.id, nil, ResourceSubscription::DISPUTE_WON_RESOURCE_NAME)
        end

        it "sets the chargeback reversed flag" do
          Purchase.handle_charge_event(@e)
          expect(@p.reload.chargeback_reversed).to be(true)
        end

        describe "purchase involves an affiliate" do
          let(:user) { @u }
          let(:merchant_account) { create(:merchant_account, user:) }
          let(:link) { @l }
          let(:affiliate_user) { create(:affiliate_user) }
          let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: user, affiliate_basis_points: 2000, products: [link]) }
          let(:purchase) do
            issued_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100)
            settled_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110)
            gumroad_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30)
            merchant_account_gross_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110)
            merchant_account_net_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 80)
            create(
                :purchase_with_balance,
                link:, seller: user, stripe_transaction_id: "ch_zitkxbhds3zqlt", merchant_account:,
                total_transaction_cents: 100, fee_cents: 30,
                affiliate: direct_affiliate,
                flow_of_funds: FlowOfFunds.new(
                    issued_amount:,
                    settled_amount:,
                    gumroad_amount:,
                    merchant_account_gross_amount:,
                    merchant_account_net_amount:
                    )
            )
          end
          let(:event_1_flow_of_funds) do
            issued_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: -100)
            settled_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -110)
            gumroad_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: -30)
            merchant_account_gross_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -110)
            merchant_account_net_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: -80)
            FlowOfFunds.new(
                issued_amount:,
                settled_amount:,
                gumroad_amount:,
                merchant_account_gross_amount:,
                merchant_account_net_amount:
                )
          end
          let(:event_1) { build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt", flow_of_funds: event_1_flow_of_funds) }
          let(:event_2_flow_of_funds) do
            issued_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: 100)
            settled_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110)
            gumroad_amount = FlowOfFunds::Amount.new(currency: Currency::USD, cents: 30)
            merchant_account_gross_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 110)
            merchant_account_net_amount = FlowOfFunds::Amount.new(currency: Currency::CAD, cents: 80)
            FlowOfFunds.new(
                issued_amount:,
                settled_amount:,
                gumroad_amount:,
                merchant_account_gross_amount:,
                merchant_account_net_amount:
                )
          end
          let(:event_2) { build(:charge_event_dispute_won, charge_id: "ch_zitkxbhds3zqlt", flow_of_funds: event_2_flow_of_funds) }

          before do
            purchase.reload
            expect(purchase.purchase_success_balance.amount_cents).to eq(6) # 100c - 20c (affiliate fees) + 19c (affiliate's share of Gumroad fee) - 10c (10% flat fee) - 50c - 3c (2.9% cc fee) - (30c fixed cc fee)
            expect(purchase.affiliate_credit.affiliate_credit_success_balance.amount_cents).to eq(1)
            allow_any_instance_of(Purchase).to receive(:fight_chargeback).and_return(true)
            Purchase.handle_charge_event(event_1)
            purchase.reload
            expect(purchase.purchase_chargeback_balance.amount_cents).to eq(0)
            expect(purchase.affiliate_credit.affiliate_credit_chargeback_balance.amount_cents).to eq(0)
          end

          it "creates two credits" do
            expect { Purchase.handle_charge_event(event_2) }.to change { Credit.count }.by(2)
          end

          it "credits the creator" do
            Purchase.handle_charge_event(event_2)
            expect(purchase.seller.credits.last.amount_cents).to eq(purchase.payment_cents - purchase.affiliate_credit_cents)
            expect(purchase.seller.credits.last.chargebacked_purchase_id).to eq(purchase.id)
            expect(purchase.seller.credits.last.merchant_account_id).to eq(purchase.merchant_account_id)
          end

          it "credits the affiliate" do
            Purchase.handle_charge_event(event_2)
            expect(purchase.affiliate_credit.affiliate_user.credits.last.amount_cents).to eq(purchase.affiliate_credit_cents)
            expect(purchase.affiliate_credit.affiliate_user.credits.last.chargebacked_purchase_id).to eq purchase.id
            expect(purchase.affiliate_credit.affiliate_user.credits.last.merchant_account_id).to eq(MerchantAccount.gumroad(purchase.charge_processor_id).id)
          end

          it "updates the balance of the creator" do
            Purchase.handle_charge_event(event_2)
            expect(purchase.seller.credits.last.balance.amount_cents).to eq(6) # 100c - 20c (affiliate fees) + 19c (affiliate's share of Gumroad fee) - 10c (10% flat fee) -50c - 3c (2.9% cc fee) - (30c fixed cc fee)
            expect(purchase.seller.credits.last.balance.merchant_account_id).to eq(purchase.merchant_account_id)
            expect(purchase.seller.credits.last.balance.merchant_account_id).to eq(purchase.purchase_success_balance.merchant_account_id)
          end

          it "updates the balance of the affiliate" do
            Purchase.handle_charge_event(event_2)
            expect(purchase.affiliate_credit.affiliate_user.credits.last.balance.amount_cents).to eq(1)
            expect(purchase.affiliate_credit.affiliate_user.credits.last.balance.merchant_account_id).to eq(MerchantAccount.gumroad(purchase.charge_processor_id).id)
            expect(purchase.affiliate_credit.affiliate_user.credits.last.balance.merchant_account_id).to eq(purchase.affiliate_credit.affiliate_credit_success_balance.merchant_account_id)
          end

          it "creates two balance transactions for the dispute won" do
            Purchase.handle_charge_event(event_2)
            balance_transaction_1, balance_transaction_2 = BalanceTransaction.last(2)

            expect(balance_transaction_1.user).to eq(affiliate_user)
            expect(balance_transaction_1.merchant_account).to eq(purchase.affiliate_merchant_account)
            expect(balance_transaction_1.refund).to eq(purchase.refunds.last)
            expect(balance_transaction_1.issued_amount_currency).to eq(Currency::USD)
            expect(balance_transaction_1.issued_amount_gross_cents).to eq(purchase.affiliate_credit_cents)
            expect(balance_transaction_1.issued_amount_net_cents).to eq(purchase.affiliate_credit_cents)
            expect(balance_transaction_1.holding_amount_currency).to eq(Currency::USD)
            expect(balance_transaction_1.holding_amount_gross_cents).to eq(purchase.affiliate_credit_cents)
            expect(balance_transaction_1.holding_amount_net_cents).to eq(purchase.affiliate_credit_cents)

            expect(balance_transaction_2.user).to eq(user)
            expect(balance_transaction_2.merchant_account).to eq(purchase.merchant_account)
            expect(balance_transaction_2.refund).to eq(purchase.refunds.last)
            expect(balance_transaction_2.issued_amount_currency).to eq(Currency::USD)
            expect(balance_transaction_2.issued_amount_currency).to eq(event_2_flow_of_funds.issued_amount.currency)
            expect(balance_transaction_2.issued_amount_gross_cents).to eq(purchase.total_transaction_cents)
            expect(balance_transaction_2.issued_amount_gross_cents).to eq(event_2_flow_of_funds.issued_amount.cents)
            expect(balance_transaction_2.issued_amount_net_cents).to eq((purchase.payment_cents - purchase.affiliate_credit_cents))
            expect(balance_transaction_2.holding_amount_currency).to eq(Currency::CAD)
            expect(balance_transaction_2.holding_amount_currency).to eq(event_2_flow_of_funds.merchant_account_gross_amount.currency)
            expect(balance_transaction_2.holding_amount_currency).to eq(event_2_flow_of_funds.merchant_account_net_amount.currency)
            expect(balance_transaction_2.holding_amount_gross_cents).to eq(event_2_flow_of_funds.merchant_account_gross_amount.cents)
            expect(balance_transaction_2.holding_amount_net_cents).to eq(event_2_flow_of_funds.merchant_account_net_amount.cents)
          end
        end

        context "for a subscription purchase" do
          before do
            transaction_id = "ch_zitkxbhds3zqlt"
            purchase = create(:membership_purchase, stripe_transaction_id: transaction_id,
                                                    price_cents: 100, chargeback_date: Date.today - 10.days)
            @subscription = purchase.subscription
            @subscription.cancel_effective_immediately!(by_buyer: true)
            expect(@subscription.reload).not_to be_alive

            @event = build(:charge_event_dispute_won, charge_id: transaction_id)
          end

          it "restarts the subscription" do
            Purchase.handle_charge_event(@event)

            @subscription.reload
            expect(@subscription).to be_alive
            expect(@subscription.cancelled_at).to be_nil
            expect(@subscription.user_requested_cancellation_at).to be_nil
          end

          it "notifies the customer with a custom message" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            allow(CustomerMailer).to receive(:subscription_restarted).and_return(mail_double)

            Purchase.handle_charge_event(@event)

            expect(CustomerMailer).to have_received(:subscription_restarted).with(@subscription.id, Subscription::ResubscriptionReason::PAYMENT_ISSUE_RESOLVED)
          end
        end

        context "for a gift purchase" do
          before do
            product = create(:product, price_cents: 600)
            gifter_email = "gifter@foo.com"
            giftee_email = "giftee@foo.com"
            transaction_id = "ch_12345"
            gift = create(:gift, gifter_email:, giftee_email:, link: product)
            @gifter_purchase = create(:purchase, link: product, price_cents: product.price_cents, email: gifter_email,
                                                 chargeback_date: Date.today - 10.days, stripe_transaction_id: transaction_id)
            gift.gifter_purchase = @gifter_purchase
            @gifter_purchase.is_gift_sender_purchase = true
            @gifter_purchase.save!
            @giftee_purchase = gift.giftee_purchase = create(:purchase, link: product, email: giftee_email, price_cents: 0,
                                                                        stripe_transaction_id: nil, stripe_fingerprint: nil, chargeback_date: Date.today - 10.days,
                                                                        is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
            gift.mark_successful
            gift.save!

            @event = build(:charge_event_dispute_won, charge_id: transaction_id)
          end

          it "marks both gifter and giftee purchases as chargeback reversed" do
            expect(@gifter_purchase.chargedback?).to be true
            expect(@giftee_purchase.chargedback?).to be true
            expect(@gifter_purchase.chargeback_reversed?).to be false
            expect(@giftee_purchase.chargeback_reversed?).to be false

            Purchase.handle_charge_event(@event)

            expect(@gifter_purchase.reload.chargeback_reversed?).to be true
            expect(@giftee_purchase.reload.chargeback_reversed?).to be true
          end
        end

        describe "dispute object" do
          let!(:purchase) { create(:purchase, link: @l, seller: @l.user, stripe_transaction_id: "1", price_cents: 100, fee_cents: 30, total_transaction_cents: 100, chargeback_date: Time.current) }
          let(:event) { build(:charge_event_dispute_won, charge_id: "1", extras: { charge_processor_dispute_id: "2" }) }
          let(:frozen_time) { Time.zone.local(2015, 9, 8, 4, 57) }

          describe "dispute object already exists for purchase" do
            describe "existing dispute object has won state already" do
              before do
                Purchase.handle_charge_event(event)
              end

              it "raises an error because the dispute cannot be transitioned into won twice" do
                expect { Purchase.handle_charge_event(event) }.to raise_error(StateMachines::InvalidTransition)
              end
            end

            describe "existing dispute object has lost state already" do
              before do
                Purchase.handle_charge_event(event)
                purchase.dispute.state = :lost
                purchase.dispute.save!
                travel_to(frozen_time) do
                  Purchase.handle_charge_event(event)
                end
              end

              it "marks the dispute as won" do
                expect { Purchase.handle_charge_event(event) }.to raise_error(StateMachines::InvalidTransition)
                purchase.reload
                expect(purchase.dispute.state).to eq("won")
                expect(purchase.dispute.won_at).to eq(frozen_time)
              end
            end

            describe "existing dispute object has created state" do
              before do
                Purchase.handle_charge_event(event)
                purchase.reload
                purchase.dispute.state = :created
                purchase.dispute.save!
                travel_to(frozen_time) do
                  Purchase.handle_charge_event(event)
                end
                purchase.reload
              end

              it "does not create a new dispute" do
                expect(Dispute.where(purchase_id: purchase.id).count).to eq(1)
              end

              it "marks the dispute as won" do
                purchase.reload
                expect(purchase.dispute.state).to eq("won")
                expect(purchase.dispute.won_at).to eq(frozen_time)
              end

              it "references the dispute on the credit" do
                purchase.reload
                expect(Credit.last.dispute).to eq(purchase.dispute)
              end
            end
          end

          describe "dispute object doesn't yet exist for purchase" do
            before do
              travel_to(frozen_time) do
                Purchase.handle_charge_event(event)
              end
              purchase.reload
            end

            it "creates a dispute" do
              expect(purchase.dispute).to be_a(Dispute)
            end

            it "sets the disputes charge processor id from the purchase" do
              expect(purchase.dispute.charge_processor_id).to eq(purchase.charge_processor_id)
            end

            it "sets the dipsutes charge processor dispute id from the event" do
              expect(purchase.dispute.charge_processor_dispute_id).to eq(event.extras[:charge_processor_dispute_id])
            end

            it "marks the dispute as won" do
              expect(purchase.dispute.state).to eq("won")
              expect(purchase.dispute.won_at).to eq(frozen_time)
            end

            it "references the dispute on the credit" do
              purchase.reload
              expect(Credit.last.dispute).to eq(purchase.dispute)
            end
          end
        end

        describe "already refunded" do
          let(:refund_flow_of_funds) { FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -100) }

          before do
            @p.refund_purchase!(refund_flow_of_funds, nil)
          end

          it "does not credit the creator" do
            count = Credit.all.count

            Purchase.handle_charge_event(@e)
            expect(Credit.all.count).to eq(count)
          end

          it "does not email the creator" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(ContactingCreatorMailer).to_not receive(:chargeback_won)
            expect(ContactingCreatorMailer).to_not receive(:credit_notification)
            Purchase.handle_charge_event(@e)
          end

          it "sets chargeback reversed flag" do
            Purchase.handle_charge_event(@e)
            expect(@p.reload.chargeback_reversed).to be(true)
          end
        end

        describe "was never chargedback in the first place" do
          before do
            @p.chargeback_date = nil
            @p.save!
          end

          it "bugsnag notifies the occurrence" do
            expect(Bugsnag).to receive(:notify).with("Invalid charge event received for successful Purchase #{@p.external_id} - " \
                                                     "received reversal won notification with ID #{@e.charge_event_id} but was not disputed.")
            Purchase.handle_charge_event(@e)
          end

          describe "should do none of the normal things that happen on this event to the purchase" do
            it "does not credit the creator" do
              count = Credit.all.count

              Purchase.handle_charge_event(@e)
              expect(Credit.all.count).to eq(count)
            end

            it "does not email the creator" do
              mail_double = double
              allow(mail_double).to receive(:deliver_later)
              expect(ContactingCreatorMailer).to_not receive(:chargeback_won)
              expect(ContactingCreatorMailer).to_not receive(:credit_notification)
              Purchase.handle_charge_event(@e)
            end

            it "does not set chargeback reversed flag" do
              Purchase.handle_charge_event(@e)
              expect(@p.reload.chargeback_reversed).to be(false)
            end
          end
        end
      end

      describe "dispute lost" do
        let(:initial_balance) { 200 }
        let(:seller) { create(:user, unpaid_balance_cents: initial_balance) }
        let(:product) { create(:product, user: seller) }
        let!(:purchase) do
          create(
              :purchase,
              link: product,
              seller:,
              stripe_transaction_id: "ch_zitkxbhds3zqlt",
              price_cents: 100,
              total_transaction_cents: 100,
              fee_cents: 30
          )
        end
        let(:event) { build(:charge_event_dispute_lost, charge_id: "ch_zitkxbhds3zqlt") }

        it "doesn't affect seller balance" do
          Purchase.handle_charge_event(event)
          purchase.reload
          seller.reload
          expect(seller.unpaid_balance_cents).to eq initial_balance
        end

        it "updates purchase current status" do
          Purchase.handle_charge_event(event)
          expect(purchase.reload.stripe_status).to eq event.comment
        end

        context "when the product doesn't have refund policy enabled" do
          it "sends an email to the seller" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(ContactingCreatorMailer).to receive(:chargeback_lost_no_refund_policy).and_return(mail_double)
            Purchase.handle_charge_event(event)
          end
        end

        context "when the product has a refund policy enabled" do
          let!(:refund_policy) { create(:product_refund_policy, seller:, product:) }

          before do
            product.update!(product_refund_policy_enabled: true)
          end

          it "doesn't send an email to the seller" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(ContactingCreatorMailer).to_not receive(:chargeback_lost_no_refund_policy)
            Purchase.handle_charge_event(event)
          end
        end

        describe "dispute object" do
          let!(:purchase) { create(:purchase, link: product, seller:, stripe_transaction_id: "1", price_cents: 100, fee_cents: 30, total_transaction_cents: 100, chargeback_date: Time.current) }
          let(:event) { build(:charge_event_dispute_lost, charge_id: "1", extras: { charge_processor_dispute_id: "2" }) }
          let(:frozen_time) { Time.zone.local(2015, 9, 8, 4, 57) }

          describe "dispute object already exists for purchase" do
            describe "existing dispute object has lost state already" do
              before do
                Purchase.handle_charge_event(event)
              end

              it "raises an error because the dispute cannot be transitioned into lost twice" do
                expect { Purchase.handle_charge_event(event) }.to raise_error(StateMachines::InvalidTransition)
              end
            end

            describe "existing dispute object has won state already" do
              before do
                Purchase.handle_charge_event(event)
                purchase.dispute.state = :won
                purchase.dispute.save!
                travel_to(frozen_time) do
                  Purchase.handle_charge_event(event)
                end
              end

              it "marks the dispute as lost" do
                expect { Purchase.handle_charge_event(event) }.to raise_error(StateMachines::InvalidTransition)
                purchase.reload
                expect(purchase.dispute.state).to eq("lost")
                expect(purchase.dispute.lost_at).to eq(frozen_time)
              end
            end

            describe "existing dispute object has created state" do
              before do
                Purchase.handle_charge_event(event)
                purchase.dispute.state = :created
                purchase.dispute.save!
                travel_to(frozen_time) do
                  Purchase.handle_charge_event(event)
                end
              end

              it "does not create a new dispute" do
                expect(Dispute.where(purchase_id: purchase.id).count).to eq(1)
              end

              it "marks the dispute as lost" do
                purchase.reload
                expect(purchase.dispute.state).to eq("lost")
                expect(purchase.dispute.lost_at).to eq(frozen_time)
              end
            end
          end

          describe "dispute object doesn't yet exist for purchase" do
            before do
              travel_to(frozen_time) do
                Purchase.handle_charge_event(event)
              end
            end

            it "creates a dispute" do
              expect(purchase.dispute).to be_a(Dispute)
            end

            it "sets the disputes charge processor id from the purchase" do
              expect(purchase.dispute.charge_processor_id).to eq(purchase.charge_processor_id)
            end

            it "sets the dipsutes charge processor dispute id from the event" do
              expect(purchase.dispute.charge_processor_dispute_id).to eq(event.extras[:charge_processor_dispute_id])
            end

            it "marks the dispute as lost" do
              expect(purchase.dispute.state).to eq("lost")
              expect(purchase.dispute.lost_at).to eq(frozen_time)
            end
          end
        end
      end
    end

    describe "bundle purchase" do
      let!(:purchase) { create(:purchase, link: create(:product, :bundle), stripe_transaction_id: "ch_12345") }

      before do
        purchase.create_artifacts_and_send_receipt!
      end

      describe "chargeback" do
        it "marks all bundle product purchases as chargedback" do
          expect_any_instance_of(Purchase).to receive(:mark_product_purchases_as_chargedback!)
          Purchase.handle_charge_event(build(:charge_event_dispute_formalized, charge_id: purchase.stripe_transaction_id))
        end
      end

      describe "chargeback reversed" do
        before { purchase.update!(chargeback_date: 1.day.ago) }

        it "marks all bundle product purchases as chargeback reversed" do
          expect_any_instance_of(Purchase).to receive(:mark_product_purchases_as_chargeback_reversed!)
          Purchase.handle_charge_event(build(:charge_event_dispute_won, charge_id: purchase.stripe_transaction_id))
        end
      end
    end
  end

  describe "#create_dispute_evidence_if_needed!" do
    let(:disputed_purchase) do create(:disputed_purchase, full_name: "John Example", street_address: "123 Sample St",
                                                          city: "San Francisco", state: "CA", country: "United States",
                                                          zip_code: "12343", ip_state: "California", ip_country: "United States",
                                                          credit_card_zipcode: "1234",  link: create(:physical_product),
                                                          url_redirect: create(:url_redirect)) end
    let!(:shipment) do create(:shipment, carrier: "UPS", tracking_number: "123456", purchase: disputed_purchase,
                                         ship_state: "shipped", shipped_at: DateTime.parse("2023-02-10 14:55:32")) end

    before do
      create_list(:purchase, 2, email: disputed_purchase.email)
      create(:dispute_formalized, purchase: disputed_purchase)
    end

    context "when purchase is not eligible" do
      before do
        allow_any_instance_of(Purchase).to receive(:eligible_for_dispute_evidence?).and_return(false)
      end

      it "does nothing" do
        expect(DisputeEvidence).not_to receive(:create_from_dispute!)
        expect(disputed_purchase.create_dispute_evidence_if_needed!).to be nil
      end
    end

    context "when the purchase is not charged back" do
      before do
        expect(disputed_purchase).to receive(:disputed?).and_return(false)
      end

      it "does nothing" do
        expect(DisputeEvidence).not_to receive(:create_from_dispute!)
        expect(disputed_purchase.create_dispute_evidence_if_needed!).to be nil
      end
    end

    it "creates a dispute evidence" do
      expect do
        disputed_purchase.create_dispute_evidence_if_needed!
      end.to change { DisputeEvidence.count }.by(1)
    end
  end

  describe "#eligible_for_dispute_evidence?" do
    let(:purchase) { create(:purchase) }

    context "when processor is PayPal" do
      before { purchase.update!(charge_processor_id: PaypalChargeProcessor.charge_processor_id) }

      it "returns false" do
        expect(purchase.eligible_for_dispute_evidence?).to be(false)
      end
    end

    context "when processor is Braintree" do
      before { purchase.update!(charge_processor_id: BraintreeChargeProcessor.charge_processor_id) }

      it "returns false" do
        expect(purchase.eligible_for_dispute_evidence?).to be(false)
      end
    end

    context "when the purchase is made via a Stripe Connect account" do
      before do
        expect_any_instance_of(MerchantAccount).to receive(:is_a_stripe_connect_account?).twice.and_return(true)
      end

      it "returns false" do
        expect(purchase.eligible_for_dispute_evidence?).to be(false)
      end
    end

    it "returns true" do
      expect(purchase.eligible_for_dispute_evidence?).to be(true)
    end
  end

  describe "#fight_chargeback" do
    let(:disputed_purchase) do create(:disputed_purchase, full_name: "John Example", street_address: "123 Sample St",
                                                          city: "San Francisco", state: "CA", country: "United States",
                                                          zip_code: "12343", ip_state: "California", ip_country: "United States",
                                                          credit_card_zipcode: "1234",  link: create(:physical_product),
                                                          url_redirect: create(:url_redirect)) end
    let!(:shipment) do create(:shipment, carrier: "UPS", tracking_number: "123456", purchase: disputed_purchase,
                                         ship_state: "shipped", shipped_at: DateTime.parse("2023-02-10 14:55:32")) end

    before do
      create_list(:purchase, 2, email: disputed_purchase.email)
      create(:dispute_formalized, purchase: disputed_purchase)

      allow(DisputeEvidence::GenerateUncategorizedTextService).to(
          receive(:perform).with(disputed_purchase).and_return("Sample uncategorized text")
      )
    end

    it "calls ChargeProcessor.fight_chargeback with correct params" do
      sample_image = File.read(Rails.root.join("spec", "support", "fixtures", "test-small.jpg"))
      allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform).with(disputed_purchase).and_return(sample_image)
      disputed_purchase.create_dispute_evidence_if_needed!

      expect(ChargeProcessor).to receive(:fight_chargeback) do |charge_processor_id, stripe_transaction_id, dispute_evidence|
        expect(charge_processor_id).to eq disputed_purchase.charge_processor_id
        expect(stripe_transaction_id).to eq disputed_purchase.stripe_transaction_id
        expect(dispute_evidence.customer_purchase_ip).to eq disputed_purchase.ip_address
        expect(dispute_evidence.customer_email).to eq disputed_purchase.email
        expect(dispute_evidence.uncategorized_text).to eq "Sample uncategorized text"
        expect(dispute_evidence.purchased_at).to eq disputed_purchase.created_at
        expect(dispute_evidence.billing_address).to eq "123 Sample St, San Francisco, CA, 12343, United States"
        expect(dispute_evidence.shipping_address).to eq "123 Sample St, San Francisco, CA, 12343, United States"
        expect(dispute_evidence.receipt_image).to be_attached
        expect(dispute_evidence.shipping_carrier).to eq "UPS"
        expect(dispute_evidence.shipped_at).to eq shipment.shipped_at
        expect(dispute_evidence.shipping_tracking_number).to eq shipment.tracking_number
      end

      disputed_purchase.fight_chargeback
    end
  end

  describe "fighting chargeback during dispute formalized" do
    it "fights chargeback via stripe" do
      user = create(:user, unpaid_balance_cents: 200)
      link = create(:product, user:)
      purchase = create(:purchase, link:, seller: user, stripe_transaction_id: "ch_zitkxbhds3zqlt", price_cents: 100,
                                   total_transaction_cents: 100, fee_cents: 30)
      event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt")
      Purchase.handle_charge_event(event)
      expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
    end
  end

  describe "#disputed?", :vcr do
    describe "for a Charge" do
      it "returns true if disputed_at is set" do
        expect(create(:charge, disputed_at: Date.today).disputed?).to be true
      end

      it "returns false if disputed_at is not set" do
        expect(create(:charge, disputed_at: nil).disputed?).to be false
      end
    end

    describe "for a Purchase" do
      it "returns true if chargeback_date is set" do
        expect(create(:purchase, chargeback_date: Date.today).disputed?).to be true
      end

      it "returns false if chargeback_date is not set" do
        expect(create(:purchase, chargeback_date: nil).disputed?).to be false
      end
    end
  end
end
