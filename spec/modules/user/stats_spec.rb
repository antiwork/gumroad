# frozen_string_literal: true

require "spec_helper"

describe User::Stats, :vcr do
  before do
    @user = create(:user, timezone: "London")
  end

  describe "#rank" do
    let(:year) { 2024 }
    let(:response) { OpenStruct.new(aggregations: OpenStruct.new(sellers: OpenStruct.new(buckets: buckets))) }
    let(:buckets) do
      [
        { "key" => 999, "total_sales" => { "value" => 2_000_00 } },
        { "key" => @user.id, "total_sales" => { "value" => 1_000_00 } },
      ]
    end

    it "returns the 1-based rank when the seller is present" do
      allow(PurchaseSearchService).to receive(:search).and_return(response)

      expect(@user.rank(year:)).to eq(2)
    end

    it "returns nil when the seller is not in the top buckets" do
      allow(PurchaseSearchService).to receive(:search).and_return(
        OpenStruct.new(aggregations: OpenStruct.new(sellers: OpenStruct.new(buckets: [{ "key" => 999 }])))
      )

      expect(@user.rank(year:)).to be_nil
    end

    it "returns nil and logs when search fails" do
      allow(PurchaseSearchService).to receive(:search).and_raise(StandardError, "boom")
      expect(Rails.logger).to receive(:error).with(/Failed to compute creator rank/)

      expect(@user.rank(year:)).to be_nil
    end
  end

  describe "scopes" do
    describe ".by_sales_revenue" do
      it "excludes not_charged purchases from revenue total" do
        product = create(:product, user: @user)
        create(:purchase, link: product, purchase_state: "not_charged")
        user_with_sales = create(:user)
        product_with_sales = create(:product, user: user_with_sales)
        create(:purchase, link: product_with_sales, purchase_state: "successful")

        expect(User.by_sales_revenue(limit: 10)).to eq [user_with_sales]
      end
    end
  end

  describe "analytics data" do
    describe "fees_cents_for_balances" do
      before do
        @user = create(:user)
        link = create(:product, user: @user, price_cents: 20_00)
        (0..5).each do |weeks_count|
          travel_to(weeks_count.weeks.ago) do
            purchase = create(:purchase_in_progress, link:, chargeable: create(:chargeable))
            purchase.process!
            purchase.update_balance_and_mark_successful!
          end
        end
      end

      it "calculates the fees for the given balances properly" do
        balance_ids = @user.unpaid_balances.map(&:id)
        fees_for_balances = @user.fees_cents_for_balances(balance_ids)
        expect(fees_for_balances).to eq 2028
      end

      it "calculates the fees for the given balances that includes a refund" do
        purchase = Purchase.last
        purchase.refund_and_save!(nil)

        balance_ids = @user.unpaid_balances.map(&:id)
        fees_for_balances = @user.fees_cents_for_balances(balance_ids)
        expect(fees_for_balances).to eq 1760
      end

      it "calculates the fees correctly for the given balances which include a chargeback" do
        purchase = Purchase.last
        purchase.stripe_transaction_id = "ch_zitkxbhds3zqlt"
        purchase.save!
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt")

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        fees_for_balances = @user.fees_cents_for_balances(balance_ids)
        expect(fees_for_balances).to eq (2028 - 338)
      end

      it "calculates the fees correctly for the given balances which include a chargeback with a partial refund on same purchase" do
        purchase = Purchase.last
        purchase.refund_partial_purchase!(9_00, @user.id)
        purchase.stripe_transaction_id = "ch_zitkxbhds3zqlt"
        purchase.save!
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt", flow_of_funds: nil)

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        fees_for_balances = @user.fees_cents_for_balances(balance_ids)
        expect(fees_for_balances).to eq (2028 - 238 + 52)
      end

      it "calculates the fees correctly for the given balances which include a refund and a chargeback" do
        purchases = Purchase.last(2)
        purchases.first.refund_and_save!(nil)

        purchase = purchases.last
        purchase.stripe_transaction_id = "ch_zitkxbhds3zqlt"
        purchase.save!
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt")

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        fees_for_balances = @user.fees_cents_for_balances(balance_ids)
        expect(fees_for_balances).to eq 1422
      end
    end

    describe "refunds_cents_for_balances" do
      before do
        @user = create(:user)
        link = create(:product, user: @user, price_cents: 20_00)
        (0..5).each do |weeks_count|
          travel_to(weeks_count.weeks.ago) do
            purchase = create(:purchase_in_progress, link:, chargeable: create(:chargeable))
            purchase.process!
            purchase.update_balance_and_mark_successful!
          end
        end
      end

      it "calculates the refunds when no refunds exist" do
        balance_ids = @user.unpaid_balances.map(&:id)
        refunds_cents_for_balances = @user.refunds_cents_for_balances(balance_ids)
        expect(refunds_cents_for_balances).to eq 0
      end

      it "calculates the refunds for the given balances that includes a full refund" do
        purchase = Purchase.last
        purchase.refund_and_save!(nil)

        balance_ids = @user.unpaid_balances.map(&:id)
        refunds_cents_for_balances = @user.refunds_cents_for_balances(balance_ids)
        expect(refunds_cents_for_balances).to eq purchase.price_cents
      end

      it "calculates the refunds for the given balances that includes a partial refund" do
        purchase = Purchase.last
        purchase.refund_and_save!(nil, amount_cents: purchase.price_cents - 10)

        balance_ids = @user.unpaid_balances.map(&:id)
        refunds_cents_for_balances = @user.refunds_cents_for_balances(balance_ids)
        expect(refunds_cents_for_balances).to eq(purchase.price_cents - 10)
      end

      it "calculates the refunds for the given balances that includes a partial refund and a full refund" do
        purchase1 = Purchase.where(stripe_refunded: false).last
        purchase1.refund_and_save!(nil)

        purchase2 = Purchase.where(stripe_refunded: false).last
        purchase2.refund_and_save!(nil, amount_cents: purchase2.price_cents - 10)

        balance_ids = @user.unpaid_balances.map(&:id)
        refunds_cents_for_balances = @user.refunds_cents_for_balances(balance_ids)
        expect(refunds_cents_for_balances).to eq(purchase1.price_cents + purchase2.price_cents - 10)
      end
    end

    describe "affiliate_credit_cents_for_balances" do
      before do
        seller = create(:user)
        link = create(:product, user: seller, price_cents: 20_00)
        @user = create(:user)
        direct_affiliate = create(:direct_affiliate, seller:, affiliate_user: @user, apply_to_all_products: true)
        (0..5).each do |weeks_count|
          travel_to(weeks_count.weeks.ago) do
            purchase = create(:purchase_in_progress, link:, chargeable: create(:chargeable), affiliate: direct_affiliate)
            purchase.process!
            purchase.update_balance_and_mark_successful!
          end
        end
      end

      it "calculates the affiliate credit cents for the given balances properly" do
        balance_ids = @user.unpaid_balances.map(&:id)
        affiliate_credits_balances = @user.affiliate_credit_cents_for_balances(balance_ids)
        expect(affiliate_credits_balances).to eq 294
      end

      it "calculates the affiliate fees for the given balances that includes a refund of an old sale" do
        purchase = Purchase.last
        purchase.balance_transactions.each do |bt|
          bt.balance.mark_processing!
          bt.balance.mark_paid!
        end
        purchase.refund_and_save!(nil)

        balance_ids = @user.unpaid_balances.map(&:id)
        affiliate_credits_balances = @user.affiliate_credit_cents_for_balances(balance_ids)
        expect(affiliate_credits_balances).to eq 196
      end


      it "calculates the affiliate fees correctly for the given balances which include a chargeback of an old sale" do
        purchase = Purchase.last
        purchase.stripe_transaction_id = "ch_zitkxbhds3zqlt"
        purchase.save!
        purchase.balance_transactions.each do |bt|
          bt.balance.mark_processing!
          bt.balance.mark_paid!
        end
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt")

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        affiliate_credits_balances = @user.affiliate_credit_cents_for_balances(balance_ids)
        expect(affiliate_credits_balances).to eq 196
      end

      it "calculates the affiliate fees correctly for the given balances which include a refund and a chargeback of old sales" do
        purchases = Purchase.last(2)
        purchases.each do |purchase|
          purchase.balance_transactions.each do |bt|
            bt.balance.mark_processing!
            bt.balance.mark_paid!
          end
        end

        purchases.first.refund_and_save!(nil)

        purchase = purchases.last
        purchase.stripe_transaction_id = "ch_zitkxbhds3zqlt"
        purchase.save!
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt")

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        affiliate_credits_balances = @user.affiliate_credit_cents_for_balances(balance_ids)
        expect(affiliate_credits_balances).to eq 98
      end
    end

    describe "affiliate_fee_cents_for_balances" do
      before do
        @user = create(:user)
        link = create(:product, user: @user, price_cents: 20_00)
        direct_affiliate = create(:direct_affiliate, seller: @user, affiliate_user: create(:user), apply_to_all_products: true)
        (0..5).each do |weeks_count|
          travel_to(weeks_count.weeks.ago) do
            purchase = create(:purchase_in_progress, link:, chargeable: create(:chargeable), affiliate: direct_affiliate)
            purchase.process!
            purchase.update_balance_and_mark_successful!
          end
        end
      end

      it "calculates the affiliate fees for the given balances properly" do
        balance_ids = @user.unpaid_balances.map(&:id)
        affiliate_fees_for_balances = @user.affiliate_fee_cents_for_balances(balance_ids)
        expect(affiliate_fees_for_balances).to eq 294
      end

      it "calculates the affiliate fees for the given balances that includes a refund of an old sale" do
        purchase = Purchase.last
        purchase.balance_transactions.each do |bt|
          bt.balance.mark_processing!
          bt.balance.mark_paid!
        end
        purchase.refund_and_save!(nil)

        balance_ids = @user.unpaid_balances.map(&:id)
        affiliate_fees_for_balances = @user.affiliate_fee_cents_for_balances(balance_ids)
        expect(affiliate_fees_for_balances).to eq 196
      end

      it "calculates the affiliate fees correctly for the given balances which include a chargeback of an old sale" do
        purchase = Purchase.last
        purchase.stripe_transaction_id = "ch_zitkxbhds3zqlt"
        purchase.save!
        purchase.balance_transactions.each do |bt|
          bt.balance.mark_processing!
          bt.balance.mark_paid!
        end
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt")

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        affiliate_fees_for_balances = @user.affiliate_fee_cents_for_balances(balance_ids)
        expect(affiliate_fees_for_balances).to eq 196
      end

      it "calculates the affiliate fees correctly for the given balances which include a refund and a chargeback of old sales" do
        purchases = Purchase.last(2)
        purchases.each do |purchase|
          purchase.balance_transactions.each do |bt|
            bt.balance.mark_processing!
            bt.balance.mark_paid!
          end
        end

        purchases.first.refund_and_save!(nil)

        purchase = purchases.last
        purchase.stripe_transaction_id = "ch_zitkxbhds3zqlt"
        purchase.save!
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt")

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        affiliate_fees_for_balances = @user.affiliate_fee_cents_for_balances(balance_ids)
        expect(affiliate_fees_for_balances).to eq 98
      end
    end

    describe "#chargebacks_cents_for_balances" do
      before do
        product = create(:product, user: @user, price_cents: 20_00)
        5.times do |weeks_count|
          travel_to(weeks_count.weeks.ago) do
            create(:purchase_with_balance, link: product, chargeable: create(:chargeable))
          end
        end
      end

      it "calculates chargebacks when no chargebacks exist" do
        balance_ids = @user.unpaid_balances.map(&:id)
        chargebacks_cents_for_balances = @user.chargebacks_cents_for_balances(balance_ids)

        expect(balance_ids.count.positive?).to be(true)
        expect(chargebacks_cents_for_balances).to eq 0
      end

      it "calculates chargebacks with full chargeback" do
        purchase = Purchase.last
        purchase.update!(stripe_transaction_id: "ch_zitkxbhds3zqlt")
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt", flow_of_funds: nil)

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        chargebacks_cents_for_balances = @user.chargebacks_cents_for_balances(balance_ids)
        expect(chargebacks_cents_for_balances).to eq 20_00
      end

      it "calculates chargebacks with partial chargeback" do
        purchase = Purchase.last
        purchase.refund_partial_purchase!(9_00, @user.id)
        purchase.update!(stripe_transaction_id: "ch_zitkxbhds3zqlt")
        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt", flow_of_funds: nil)

        Purchase.handle_charge_event(event)
        expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)

        balance_ids = @user.unpaid_balances.map(&:id)
        chargebacks_cents_for_balances = @user.chargebacks_cents_for_balances(balance_ids)
        expect(chargebacks_cents_for_balances).to eq 11_00
      end

      it "calculates chargebacks for multiple balance transactions" do
        purchases = Purchase.last(2)

        event = build(:charge_event_dispute_formalized, charge_id: "ch_zitkxbhds3zqlt", flow_of_funds: nil)
        purchases.each do |purchase|
          purchase.update!(stripe_transaction_id: "ch_zitkxbhds3zqlt")
          Purchase.handle_charge_event(event)
          expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
        end

        balance_ids = @user.unpaid_balances.map(&:id)
        chargebacks_cents_for_balances = @user.chargebacks_cents_for_balances(balance_ids)
        expect(chargebacks_cents_for_balances).to eq 20_00 * 2
      end
    end

    describe "#credits_cents_for_balances" do
      before do
        create(:merchant_account_stripe, user: @user)
        5.times do
          Credit.create_for_financing_paydown!(purchase: create(:purchase, link: create(:product, user: @user)), amount_cents: -250, merchant_account: @user.stripe_account, stripe_loan_paydown_id: "cptxn_12345")
          Credit.create_for_credit!(user: @user, amount_cents: 1000, crediting_user: create(:user))
          stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
          Credit.create_for_manual_paydown_on_stripe_loan!(amount_cents: -2000, merchant_account: @user.stripe_account, stripe_loan_paydown_id: "cptxn_#{SecureRandom.uuid}")
        end
      end

      it "does not include the stripe loan repayment credits" do
        balance_ids = @user.unpaid_balances.map(&:id)
        loan_repayment_cents = @user.credits_cents_for_balances(balance_ids)

        expect(balance_ids.count.positive?).to be(true)
        expect(loan_repayment_cents).to eq(5000) # 1000 * 5
      end
    end

    describe "#loan_repayment_cents_for_balances" do
      before do
        create(:merchant_account_stripe, user: @user)
        5.times do
          Credit.create_for_financing_paydown!(purchase: create(:purchase, link: create(:product, user: @user)), amount_cents: -250, merchant_account: @user.stripe_account, stripe_loan_paydown_id: "cptxn_#{SecureRandom.uuid}")
          Credit.create_for_credit!(user: @user, amount_cents: 1000, crediting_user: create(:user))
        end
        stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
        Credit.create_for_manual_paydown_on_stripe_loan!(amount_cents: -2000, merchant_account: @user.stripe_account, stripe_loan_paydown_id: "cptxn_#{SecureRandom.uuid}")
      end

      it "calculates the total loan repayment deduction made by stripe" do
        balance_ids = @user.unpaid_balances.map(&:id)
        loan_repayment_cents = @user.loan_repayment_cents_for_balances(balance_ids)

        expect(balance_ids.count.positive?).to be(true)
        expect(loan_repayment_cents).to eq(-3250) # -250 * 5 - 2000
      end
    end

    describe "PayPal stats" do
      before :each do
        @creator = create(:user)

        create(:user_compliance_info, user: @creator, country: "India")
        zip_tax_rate = create(:zip_tax_rate, country: "IN", state: nil, zip_code: nil, combined_rate: 0.2, is_seller_responsible: true)
        @creator.zip_tax_rates << zip_tax_rate
        @creator.save!

        create(:merchant_account_paypal, user: @creator, charge_processor_merchant_id: "CJS32DZ7NDN5L")

        @product1 = create(:product, price_cents: 10_00, user: @creator)
        @product2 = create(:product, price_cents: 15_00, user: @creator)
        @product3 = create(:product, price_cents: 150_00, user: @creator)

        direct_affiliate = create(:direct_affiliate, seller: @creator, affiliate_user: create(:affiliate_user), affiliate_basis_points: 2500, products: [@product1, @product2, @product3])

        @payout_start_date = 14.days.ago.to_date
        @payout_end_date = 7.days.ago.to_date

        @old_purchase_to_refund = create(:purchase_in_progress, link: @product1, seller: @creator, chargeable: create(:native_paypal_chargeable),
                                                                card_type: CardType::PAYPAL, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                                affiliate: direct_affiliate, country: "India")
        @old_purchase_to_refund.process!
        @old_purchase_to_refund.update_balance_and_mark_successful!
        @old_purchase_to_refund.update_attribute(:succeeded_at, @payout_start_date - 1)

        @old_purchase_to_chargeback = create(:purchase_in_progress, link: @product3, seller: @creator, chargeable: create(:native_paypal_chargeable),
                                                                    card_type: CardType::PAYPAL, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                                    affiliate: direct_affiliate)
        @old_purchase_to_chargeback.process!
        @old_purchase_to_chargeback.update_balance_and_mark_successful!
        @old_purchase_to_chargeback.update_attribute(:succeeded_at, @payout_start_date - 1)

        create(:purchase_in_progress, link: @product1, seller: @creator, created_at: 12.days.ago, chargeable: create(:native_paypal_chargeable),
                                      card_type: CardType::PAYPAL, charge_processor_id: PaypalChargeProcessor.charge_processor_id, affiliate: direct_affiliate)
        @purchase_to_chargeback = create(:purchase_in_progress, link: @product1, seller: @creator, chargeable: create(:native_paypal_chargeable),
                                                                card_type: CardType::PAYPAL, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                                affiliate: direct_affiliate)
        @purchase_to_chargeback.process!
        @purchase_to_chargeback.update_balance_and_mark_successful!
        @purchase_to_chargeback.update_attribute(:succeeded_at, @payout_start_date.noon)

        @purchase_with_tax = create(:purchase_in_progress, link: @product2, seller: @creator, created_at: 13.days.ago,
                                                           chargeable: create(:native_paypal_chargeable), country: "India",
                                                           card_type: CardType::PAYPAL, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
        @purchase_with_tax.process!
        @purchase_with_tax.update_balance_and_mark_successful!
        @purchase_with_tax.update_attribute(:succeeded_at, @payout_start_date + 2)

        @purchase_with_affiliate = create(:purchase_in_progress, link: @product3, seller: @creator, created_at: 13.days.ago,
                                                                 chargeable: create(:native_paypal_chargeable),
                                                                 card_type: CardType::PAYPAL, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                                                 affiliate: direct_affiliate)
        @purchase_with_affiliate.process!
        @purchase_with_affiliate.update_balance_and_mark_successful!
        @purchase_with_affiliate.update_attribute(:succeeded_at, @payout_start_date + 3)

        @purchase_to_refund = create(:purchase_in_progress, link: @product3, seller: @creator, created_at: 10.days.ago,
                                                            chargeable: create(:native_paypal_chargeable),
                                                            card_type: CardType::PAYPAL, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
        @purchase_to_refund.process!
        @purchase_to_refund.update_balance_and_mark_successful!
        @purchase_to_refund.update_attribute(:succeeded_at, @payout_end_date.noon)

        create(:purchase, link: @product3, charge_processor_id: StripeChargeProcessor.charge_processor_id, seller: @creator,
                          chargeable: create(:native_paypal_chargeable), card_type: CardType::VISA, succeeded_at: @payout_start_date + 3)
        create(:purchase, link: @product3, charge_processor_id: BraintreeChargeProcessor.charge_processor_id, seller: @creator,
                          chargeable: create(:native_paypal_chargeable), card_type: CardType::PAYPAL, succeeded_at: @payout_start_date + 2)

        allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
        travel_to(14.days.ago) do
          event = OpenStruct.new(created_at: Time.current,
                                 extras: {},
                                 flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD,
                                                                                       @purchase_to_chargeback.total_transaction_cents))
          @old_purchase_to_chargeback.handle_event_dispute_formalized!(event)
          @old_purchase_to_chargeback.save!

          @old_purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @old_purchase_to_refund.total_transaction_cents / 4), @creator)
        end

        travel_to(7.days.ago) do
          event = OpenStruct.new(created_at: Time.current,
                                 extras: {},
                                 flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD,
                                                                                       @purchase_to_chargeback.total_transaction_cents))
          @purchase_to_chargeback.handle_event_dispute_formalized!(event)
          @purchase_to_chargeback.save!

          @old_purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @old_purchase_to_refund.total_transaction_cents / 4), @creator)
          @purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_refund.total_transaction_cents), @creator)
        end

        travel_to(5.days.ago) do
          event = OpenStruct.new(created_at: Time.current, extras: {}, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_chargeback.total_transaction_cents))
          @purchase_with_affiliate.handle_event_dispute_formalized!(event)
          @purchase_with_affiliate.save!

          @purchase_with_tax.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_with_tax.total_transaction_cents), @creator)
        end
      end

      describe "#paypal_sales_in_duration" do
        it "returns successful sales from the duration" do
          sales = @creator.paypal_sales_in_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(sales).to match_array [@purchase_to_chargeback, @purchase_with_tax, @purchase_with_affiliate, @purchase_to_refund]
        end
      end

      describe "#paypal_refunds_in_duration" do
        it "returns refunds from the duration" do
          refunds = @creator.paypal_refunds_in_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(refunds).to eq [@old_purchase_to_refund.refunds.to_a, @purchase_to_refund.refunds.to_a].flatten
        end
      end

      describe "#paypal_sales_chargebacked_in_duration" do
        it "returns the disputes from the duration" do
          disputed_sales = @creator.paypal_sales_chargebacked_in_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(disputed_sales).to eq [@old_purchase_to_chargeback, @purchase_to_chargeback]
        end
      end

      describe "#paypal_sales_cents_for_duration" do
        it "returns total paypal direct sales amount from the duration" do
          sales_amount = @creator.paypal_sales_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(sales_amount).to eq(325_00)
        end
      end

      describe "#paypal_refunds_cents_for_duration" do
        it "returns total paypal direct refunded amount from the duration" do
          refunded_amount = @creator.paypal_refunds_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(refunded_amount).to eq(155_00)
        end
      end

      describe "#paypal_chargebacked_cents_for_duration" do
        it "returns total paypal direct chargedbacked amount from the duration" do
          disputed_amount = @creator.paypal_chargebacked_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(disputed_amount).to eq(160_00)
        end
      end

      describe "#paypal_fees_cents_for_duration" do
        it "returns net fees amount from paypal direct sales from the duration" do
          fees_amount = @creator.paypal_fees_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(fees_amount).to eq(126)
        end
      end

      describe "#paypal_returned_fees_due_to_refunds_and_chargebacks" do
        it "returns fees amount from paypal direct sales that has been returned during the duration" do
          fees_amount = @creator.paypal_returned_fees_due_to_refunds_and_chargebacks(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(fees_amount).to eq(33_24)
        end
      end

      describe "#paypal_taxes_cents_for_duration" do
        it "returns net tax amount from paypal direct sales during the duration" do
          tax_amount = @creator.paypal_taxes_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(tax_amount).to eq(0)
        end
      end

      describe "#paypal_returned_taxes_due_to_refunds_and_chargebacks" do
        it "returns tax amount from paypal direct sales that has been returned during the duration" do
          tax_amount = @creator.paypal_returned_taxes_due_to_refunds_and_chargebacks(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(tax_amount).to eq(0)
        end
      end

      describe "#paypal_affiliate_fee_cents_for_duration" do
        it "returns net affiliate fee amount from paypal direct sales during the duration" do
          affiliate_fee_amount = @creator.paypal_affiliate_fee_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(affiliate_fee_amount).to eq(-1_06)
        end
      end

      describe "#paypal_returned_affiliate_fee_cents_due_to_refunds_and_chargebacks" do
        it "returns affiliate fee amount from paypal direct sales that has been returned during the duration" do
          affiliate_fee_amount = @creator.paypal_returned_affiliate_fee_cents_due_to_refunds_and_chargebacks(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(affiliate_fee_amount).to eq(36_80)
        end
      end

      describe "#paypal_sales_data_for_duration" do
        it "returns overall sales stats from paypal direct sales during the duration" do
          paypal_sales_data = @creator.paypal_sales_data_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(paypal_sales_data).to eq({
                                            sales_cents: 325_00,
                                            refunds_cents: 155_00,
                                            chargebacks_cents: 160_00,
                                            credits_cents: 0,
                                            fees_cents: 126,
                                            direct_fees_cents: 126,
                                            discover_fees_cents: 0,
                                            direct_sales_count: 4,
                                            discover_sales_count: 0,
                                            taxes_cents: 0,
                                            affiliate_credits_cents: 0,
                                            affiliate_fees_cents: -1_06
                                          })
        end
      end

      describe "#paypal_payout_net_cents" do
        it "returns affiliate fee amount from paypal direct sales that has been returned during the duration" do
          paypal_sales_data = @creator.paypal_sales_data_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)
          paypal_payout_net_cents = @creator.paypal_payout_net_cents(paypal_sales_data)

          expect(paypal_payout_net_cents).to eq(9_80)
        end
      end

      describe "#paypal_revenue_by_product_for_duration" do
        it "returns affiliate fee amount from paypal direct sales that has been returned during the duration" do
          revenue_by_product = @creator.paypal_revenue_by_product_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(revenue_by_product).to eq({
                                             @product1.id => -320,
                                             @product2.id => 1300,
                                             @product3.id => 0,
                                           })
        end
      end
    end

    describe "Stripe Connect stats" do
      before :each do
        @creator = create(:user)
        create(:user_compliance_info, user: @creator)

        Feature.activate_user(:merchant_migration, @creator)
        create(:merchant_account_stripe_connect, user: @creator)

        @product1 = create(:product, price_cents: 10_00, user: @creator)
        @product2 = create(:product, price_cents: 15_00, user: @creator)
        @product3 = create(:product, price_cents: 150_00, user: @creator)

        direct_affiliate = create(:direct_affiliate, seller: @creator, affiliate_user: create(:affiliate_user), affiliate_basis_points: 2500, products: [@product1, @product2, @product3])

        @payout_start_date = 14.days.ago.to_date
        @payout_end_date = 7.days.ago.to_date

        create(:zip_tax_rate, country: "DE", state: nil, zip_code: nil, combined_rate: 0.2, is_seller_responsible: false)

        @old_purchase_to_refund = create(:purchase_in_progress, link: @product1, seller: @creator, chargeable: create(:chargeable),
                                                                affiliate: direct_affiliate, country: "Germany", ip_country: "Germany")
        @old_purchase_to_refund.process!
        @old_purchase_to_refund.update_balance_and_mark_successful!
        @old_purchase_to_refund.update_attribute(:succeeded_at, @payout_start_date - 1)

        @old_purchase_to_chargeback = create(:purchase_in_progress, link: @product3, seller: @creator, chargeable: create(:chargeable),
                                                                    affiliate: direct_affiliate)
        @old_purchase_to_chargeback.process!
        @old_purchase_to_chargeback.update_balance_and_mark_successful!
        @old_purchase_to_chargeback.update_attribute(:succeeded_at, @payout_start_date - 1)

        create(:purchase_in_progress, link: @product1, seller: @creator, created_at: 12.days.ago, chargeable: create(:chargeable), affiliate: direct_affiliate)
        @purchase_to_chargeback = create(:purchase_in_progress, link: @product1, seller: @creator, chargeable: create(:chargeable),
                                                                affiliate: direct_affiliate)
        @purchase_to_chargeback.process!
        @purchase_to_chargeback.update_balance_and_mark_successful!
        @purchase_to_chargeback.update_attribute(:succeeded_at, @payout_start_date.noon)

        @purchase_with_tax = create(:purchase_in_progress, link: @product2, seller: @creator, created_at: 13.days.ago,
                                                           chargeable: create(:chargeable), country: "Germany", ip_country: "Germany")
        @purchase_with_tax.process!
        @purchase_with_tax.update_balance_and_mark_successful!
        @purchase_with_tax.update_attribute(:succeeded_at, @payout_start_date + 2)

        @purchase_with_affiliate = create(:purchase_in_progress, link: @product3, seller: @creator, created_at: 13.days.ago,
                                                                 chargeable: create(:chargeable), affiliate: direct_affiliate)
        @purchase_with_affiliate.process!
        @purchase_with_affiliate.update_balance_and_mark_successful!
        @purchase_with_affiliate.update_attribute(:succeeded_at, @payout_start_date + 3)

        @purchase_to_refund = create(:purchase_in_progress, link: @product3, seller: @creator, created_at: 10.days.ago, chargeable: create(:chargeable))
        @purchase_to_refund.process!
        @purchase_to_refund.update_balance_and_mark_successful!
        @purchase_to_refund.update_attribute(:succeeded_at, @payout_end_date.noon)

        create(:purchase, link: @product3, charge_processor_id: PaypalChargeProcessor.charge_processor_id, seller: @creator,
                          chargeable: create(:native_paypal_chargeable), card_type: CardType::PAYPAL, succeeded_at: @payout_start_date + 3)
        create(:purchase, link: @product3, charge_processor_id: BraintreeChargeProcessor.charge_processor_id, seller: @creator,
                          chargeable: create(:paypal_chargeable), card_type: CardType::PAYPAL, succeeded_at: @payout_start_date + 2)

        allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
        travel_to(14.days.ago) do
          event = OpenStruct.new(created_at: Time.current,
                                 extras: {},
                                 flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD,
                                                                                       @purchase_to_chargeback.total_transaction_cents))
          @old_purchase_to_chargeback.handle_event_dispute_formalized!(event)
          @old_purchase_to_chargeback.save!

          @old_purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @old_purchase_to_refund.total_transaction_cents / 4), @creator)
        end

        travel_to(7.days.ago) do
          event = OpenStruct.new(created_at: Time.current,
                                 extras: {},
                                 flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD,
                                                                                       @purchase_to_chargeback.total_transaction_cents))
          @purchase_to_chargeback.handle_event_dispute_formalized!(event)
          @purchase_to_chargeback.save!

          @old_purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @old_purchase_to_refund.total_transaction_cents / 4), @creator)
          @purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_refund.total_transaction_cents), @creator)
        end

        travel_to(5.days.ago) do
          event = OpenStruct.new(created_at: Time.current, extras: {}, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_chargeback.total_transaction_cents))
          @purchase_with_affiliate.handle_event_dispute_formalized!(event)
          @purchase_with_affiliate.save!

          @purchase_with_tax.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_with_tax.total_transaction_cents), @creator)
        end
      end

      describe "#stripe_connect_sales_in_duration" do
        it "returns successful sales from the duration" do
          sales = @creator.stripe_connect_sales_in_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(sales).to match_array [@purchase_to_chargeback, @purchase_with_tax, @purchase_with_affiliate, @purchase_to_refund]
        end
      end

      describe "#stripe_connect_refunds_in_duration" do
        it "returns refunds from the duration" do
          refunds = @creator.stripe_connect_refunds_in_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(refunds).to eq [@old_purchase_to_refund.refunds.to_a, @purchase_to_refund.refunds.to_a].flatten
        end
      end

      describe "#stripe_connect_sales_chargebacked_in_duration" do
        it "returns the disputes from the duration" do
          disputed_sales = @creator.stripe_connect_sales_chargebacked_in_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(disputed_sales).to eq [@old_purchase_to_chargeback, @purchase_to_chargeback]
        end
      end

      describe "#stripe_connect_sales_cents_for_duration" do
        it "returns total Stripe Connect direct sales amount from the duration" do
          sales_amount = @creator.stripe_connect_sales_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(sales_amount).to eq(325_00)
        end
      end

      describe "#stripe_connect_refunds_cents_for_duration" do
        it "returns total Stripe Connect direct refunded amount from the duration" do
          refunded_amount = @creator.stripe_connect_refunds_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(refunded_amount).to eq(155_00)
        end
      end

      describe "#stripe_connect_chargebacked_cents_for_duration" do
        it "returns total Stripe Connect direct chargedbacked amount from the duration" do
          disputed_amount = @creator.stripe_connect_chargebacked_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(disputed_amount).to eq(160_00)
        end
      end

      describe "#stripe_connect_fees_cents_for_duration" do
        it "returns net fees amount from Stripe Connect direct sales from the duration" do
          fees_amount = @creator.stripe_connect_fees_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(fees_amount).to eq(126)
        end
      end

      describe "#stripe_connect_returned_fees_due_to_refunds_and_chargebacks" do
        it "returns fees amount from Stripe Connect direct sales that has been returned during the duration" do
          fees_amount = @creator.stripe_connect_returned_fees_due_to_refunds_and_chargebacks(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(fees_amount).to eq(33_24)
        end
      end

      describe "#stripe_connect_taxes_cents_for_duration" do
        it "returns net tax amount from Stripe Connect direct sales during the duration" do
          tax_amount = @creator.stripe_connect_taxes_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(tax_amount).to eq(0)
        end
      end

      describe "#stripe_connect_returned_taxes_due_to_refunds_and_chargebacks" do
        it "returns tax amount from Stripe Connect direct sales that has been returned during the duration" do
          tax_amount = @creator.stripe_connect_returned_taxes_due_to_refunds_and_chargebacks(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(tax_amount).to eq(0)
        end
      end

      describe "#stripe_connect_affiliate_fee_cents_for_duration" do
        it "returns net affiliate fee amount from Stripe Connect direct sales during the duration" do
          affiliate_fee_amount = @creator.stripe_connect_affiliate_fee_cents_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(affiliate_fee_amount).to eq(-1_06)
        end
      end

      describe "#stripe_connect_returned_affiliate_fee_cents_due_to_refunds_and_chargebacks" do
        it "returns affiliate fee amount from Stripe Connect direct sales that has been returned during the duration" do
          affiliate_fee_amount = @creator.stripe_connect_returned_affiliate_fee_cents_due_to_refunds_and_chargebacks(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(affiliate_fee_amount).to eq(36_80)
        end
      end

      describe "#stripe_connect_sales_data_for_duration" do
        it "returns overall sales stats from Stripe Connect direct sales during the duration" do
          stripe_connect_sales_data = @creator.stripe_connect_sales_data_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(stripe_connect_sales_data).to eq({
                                                    sales_cents: 325_00,
                                                    refunds_cents: 155_00,
                                                    chargebacks_cents: 160_00,
                                                    credits_cents: 0,
                                                    fees_cents: 126,
                                                    direct_fees_cents: 126,
                                                    discover_fees_cents: 0,
                                                    direct_sales_count: 4,
                                                    discover_sales_count: 0,
                                                    taxes_cents: 0,
                                                    affiliate_credits_cents: 0,
                                                    affiliate_fees_cents: -1_06
                                                  })
        end
      end

      describe "#stripe_connect_payout_net_cents" do
        it "returns affiliate fee amount from Stripe Connect direct sales that has been returned during the duration" do
          stripe_connect_sales_data = @creator.stripe_connect_sales_data_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)
          stripe_connect_payout_net_cents = @creator.stripe_connect_payout_net_cents(stripe_connect_sales_data)

          expect(stripe_connect_payout_net_cents).to eq(9_80)
        end
      end

      describe "#stripe_connect_revenue_by_product_for_duration" do
        it "returns affiliate fee amount from Stripe Connect direct sales that has been returned during the duration" do
          revenue_by_product = @creator.stripe_connect_revenue_by_product_for_duration(start_date: @payout_start_date, end_date: @payout_end_date)

          expect(revenue_by_product).to eq({
                                             @product1.id => -320,
                                             @product2.id => 1300,
                                             @product3.id => 0,
                                           })
        end
      end
    end
  end

  describe "active?" do
    it "reports users active who have created links in the last x days" do
      user = create(:user)
      create(:product, user:, created_at: 10.days.ago)
      expect(user.active?(30)).to be(true)
    end

    it "reports users active who have made sales in the last x days" do
      user = create(:user)
      link = create(:product, user:, created_at: 45.days.ago)
      create(:purchase, link:, seller: user, purchase_state: :successful)
      expect(user.active?(30)).to be(true)
    end

    it "reports users inactive who have not made sales or created links in the last x days" do
      user = create(:user)
      link = create(:product, user:, created_at: 45.days.ago)
      create(:purchase, link:, seller: user, purchase_state: :successful, created_at: 40.days.ago)
      expect(user.active?(30)).to be(false)
    end
  end

  describe "#total_amount_made_cents" do
    it "totals all the balances" do
      @user = build(:user)
      create(:balance, user: @user, date: Date.today)
      create(:balance, user: @user, date: 7.days.ago)
      create(:balance, user: @user, date: 14.days.ago)

      expect(@user.total_amount_made_cents).to eq 3000
    end
  end

  describe "#products_for_creator_analytics" do
    it "does not include deleted products that don't have sales" do
      product = create(:product, user: @user)
      expect(@user.products_for_creator_analytics).to eq [product]

      product.mark_deleted!
      expect(@user.reload.products_for_creator_analytics).to eq []
    end

    it "includes deleted products if they've had sales" do
      product = create(:product, user: @user, deleted_at: Time.current)
      create(:purchase, link: product)

      expect(@user.reload.products_for_creator_analytics).to eq [product]
    end

    it "does not include archived products that don't have sales" do
      product = create(:product, user: @user)
      expect(@user.products_for_creator_analytics).to eq [product]

      product.update!(archived: true)
      expect(@user.reload.products_for_creator_analytics).to eq []
    end

    it "includes archived products if they've had sales" do
      product = create(:product, user: @user, archived: true)
      create(:purchase, link: product)

      expect(@user.reload.products_for_creator_analytics).to eq [product]
    end

    it "orders by 'created_at DESC'" do
      product1 = create(:product, user: @user)
      product2 = nil
      product3 = nil
      travel_to(2.days.from_now) do
        product2 = create(:product, user: @user)
      end
      travel_to(4.days.from_now) do
        product3 = create(:product, user: @user, deleted_at: Time.current)
        create(:purchase, link: product3)
      end

      expect(@user.reload.products_for_creator_analytics).to eq [product3, product2, product1]
    end
  end

  describe "#last_weeks_sales" do
    it "only includes successful purchases" do
      product = create(:product, user: @user)
      created_at = Date.today.beginning_of_week(:sunday).to_datetime - 1.day
      create(:purchase, link: product, created_at:, purchase_state: "successful", price_cents: 100, fee_cents: 30)
      create(:purchase, link: product, created_at:, purchase_state: "not_charged", price_cents: 200, fee_cents: 60)
      expect(@user.last_weeks_sales).to eq 7
    end
  end

  describe "sales totals" do
    before do
      product = create(:product, user: @user)
      # Revenues as seller (with fee of 9% + 30c)
      create(:purchase, link: product, price_cents: 100)
      @unaffiliated_sales_total = 100 - 93 # price - fee
      create(:purchase, link: product, purchase_state: "not_charged", price_cents: 200) # not counted
      create(:preorder_authorization_purchase, link: product) # not counted
      create(:refunded_purchase, link: product) # not counted
      create(:disputed_purchase, link: product) # not counted
      create(:failed_purchase, link: product) # not counted
      create(:test_purchase, link: product) # not counted

      # Revenue as seller, minus direct affiliate credit
      purchase = create(:purchase, affiliate: create(:direct_affiliate, affiliate_basis_points: 1515), link: product, price_cents: 99)
      create(:refund, purchase:, amount_cents: 7, fee_cents: 2)
      affiliate_credit = create(:affiliate_credit, seller: @user, purchase:, amount_cents: 15)
      create(:affiliate_partial_refund, affiliate_credit:, amount_cents: 6)
      @direct_affiliate_sales_total = 99 - 93 - 7 + 2 - 15 + 6 # price_cents - fee - refunded amount + refunded fee - affiliate_credit_cents + affiliate refunded cents

      # Revenue as seller, minus global affiliate credit
      purchase = create(:purchase, affiliate: create(:user).global_affiliate, link: product, price_cents: 999)
      create(:refund, purchase:, amount_cents: 7, fee_cents: 2)
      affiliate_credit = create(:affiliate_credit, seller: @user, purchase:, amount_cents: 15)
      create(:affiliate_partial_refund, affiliate_credit:, amount_cents: 6)
      @global_affiliate_sales_total = 999 - 209 - 7 + 2 - 15 + 6 # price_cents - fee - refunded amount + refunded fee - affiliate_credit_cents + affiliate refunded cents

      # Revenue as affiliate
      purchase = create(:purchase, price_cents: 100, affiliate: create(:direct_affiliate, affiliate_basis_points: 2000), stripe_partially_refunded: true)
      create(:refund, purchase:, amount_cents: 7, fee_cents: 2) # refund is not counted, because product doesn't belong to @user
      affiliate_credit = create(:affiliate_credit, affiliate_user: @user, purchase:, amount_cents: 20)
      create(:affiliate_partial_refund, affiliate_credit:, amount_cents: 3)
      create(:affiliate_partial_refund, affiliate_credit:, amount_cents: 4)
      @affiliate_credits_earned = 20 - 3 - 4 # affiliate_credit_cents - affiliate refunded cents

      # This credit is not counted, because the purchase is fully refunded
      create(:affiliate_credit,
             affiliate_user: @user,
             purchase: create(:purchase, affiliate: create(:direct_affiliate, affiliate_basis_points: 2000), stripe_refunded: true),
             amount_cents: 20)
    end

    describe "#sales_cents_total" do
      it "returns the correct total" do
        expected_total = (
          @unaffiliated_sales_total +
          @direct_affiliate_sales_total +
          @global_affiliate_sales_total +
          @affiliate_credits_earned
        )

        index_model_records(Purchase)
        expect(@user.sales_cents_total).to eq(expected_total)
      end
    end
  end

  describe "#gross_sales_cents_total_as_seller", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "does not take into account refunded or not charged purchases" do
      product = create(:product, price_cents: 500, user: @user)
      create(:purchase, link: product)
      create(:purchase, link: product, stripe_refunded: true)
      create(:purchase, link: product, purchase_state: "not_charged")

      preorder_link = create(:product, price_cents: 500, is_in_preorder_state: true, user: @user)
      create(:purchase, link: preorder_link, purchase_state: "preorder_authorization_successful")
      create(:purchase, link: preorder_link, purchase_state: "preorder_authorization_successful", stripe_refunded: true)

      partially_refunded_purchase = create(:purchase, link: product, stripe_partially_refunded: true)
      partially_refunded_purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 300), partially_refunded_purchase.seller)

      expect(@user.gross_sales_cents_total_as_seller).to eq 1200.0
    end

    it "does take recommended purchase into account" do
      product = create(:product, price_cents: 500, user: @user)
      create(:purchase, link: product)
      create(:purchase, link: product, was_product_recommended: true)

      expect(@user.gross_sales_cents_total_as_seller).to eq 1000.0
    end

    it "takes only purchases that are recommended when specified" do
      product1 = create(:product, price_cents: 600, user: @user)
      create(:purchase, link: product1)
      product2 = create(:product, price_cents: 700, user: @user)
      create(:purchase, link: product2, was_product_recommended: true)

      expect(@user.gross_sales_cents_total_as_seller(recommended: true)).to eq 700.0
    end
  end

  describe "#active_subscribers?" do
    it "returns true if there are active subscriptions that are being charged using the given charge processor, else false" do
      subscription_product = create(:subscription_product, user: @user)

      subscription_using_paypal = create(:subscription, link: subscription_product, user: nil,
                                                        credit_card: create(:credit_card, chargeable: create(:native_paypal_chargeable)))
      create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription: subscription_using_paypal)

      subscription_product_2 = create(:subscription_product, user: @user)
      subscription_using_stripe = create(:subscription, link: subscription_product_2, user: nil,
                                                        credit_card: create(:credit_card))
      create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription: subscription_using_stripe)

      purchaser = create(:user, credit_card: create(:credit_card))
      subscription_with_purchaser = create(:subscription, link: subscription_product, user: purchaser)
      create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription: subscription_with_purchaser)

      expect(@user.active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_subscribers?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_subscribers?(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)).to be false

      purchaser.credit_card = create(:credit_card, chargeable: create(:native_paypal_chargeable))
      purchaser.save!

      expect(@user.active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_subscribers?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_subscribers?(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)).to be false

      subscription_using_paypal.end_subscription!
      subscription_using_stripe.cancel!
      expect(subscription_using_stripe.pending_cancellation?).to be true

      expect(@user.active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be false
      expect(@user.active_subscribers?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_subscribers?(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)).to be false

      subscription_using_stripe.cancel_effective_immediately!
      subscription_with_purchaser.cancel!
      expect(subscription_using_stripe.pending_cancellation?).to be false
      expect(subscription_with_purchaser.pending_cancellation?).to be true

      expect(@user.active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be false
      expect(@user.active_subscribers?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)).to be false
      expect(@user.active_subscribers?(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)).to be false
    end

    it "returns true if there are active subscriptions that are being charged using the given charge processor and merchant account, else false" do
      merchant_account = create(:merchant_account_stripe, user: @user)

      subscription_product = create(:subscription_product, user: @user)

      subscription_product_2 = create(:subscription_product, user: @user)
      subscription_using_stripe = create(:subscription, link: subscription_product_2, user: nil,
                                                        credit_card: create(:credit_card))
      create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription: subscription_using_stripe, merchant_account:)

      purchaser = create(:user, credit_card: create(:credit_card))
      subscription_with_purchaser = create(:subscription, link: subscription_product, user: purchaser)
      create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription: subscription_with_purchaser)

      expect(@user.active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id, merchant_account: create(:merchant_account))).to be false
      expect(@user.active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id, merchant_account:)).to be true
    end

    it "does not consider free subscriptions" do
      subscription_product = create(:subscription_product, user: @user)
      subscription_using_paypal = create(:subscription, link: subscription_product, user: nil,
                                                        credit_card: create(:credit_card, chargeable: create(:native_paypal_chargeable)))
      create(:purchase, link: subscription_product, is_original_subscription_purchase: true,
                        subscription: subscription_using_paypal, total_transaction_cents: 0)

      purchaser = create(:user, credit_card: create(:credit_card))
      subscription_with_purchaser = create(:subscription, link: subscription_product, user: purchaser)
      create(:purchase, link: subscription_product, is_original_subscription_purchase: true,
                        subscription: subscription_with_purchaser, total_transaction_cents: 0)

      expect(@user.active_subscribers?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be false
      expect(@user.active_subscribers?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)).to be false
      expect(@user.active_subscribers?(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)).to be false
    end
  end

  describe "#active_preorders?" do
    it "returns true if there are preorders that are pending to be charged using the given charge processor, else false" do
      preorder_product = create(:product, user: @user, price_cents: 500, is_in_preorder_state: true)
      create(:preorder_link, link: preorder_product, release_at: 2.days.from_now)
      preorder = create(:preorder, preorder_link: preorder_product.preorder_link)
      authorization_purchase = create(:purchase,
                                      link: preorder_product,
                                      chargeable: create(:chargeable),
                                      purchase_state: "in_progress",
                                      preorder:,
                                      is_preorder_authorization: true)
      authorization_purchase.process!
      authorization_purchase.mark_preorder_authorization_successful!
      preorder.mark_authorization_successful!

      preorder_product.update!(price_cents: 0)
      purchaser = create(:user)
      preorder = create(:preorder, preorder_link: preorder_product.preorder_link, purchaser:)
      authorization_purchase = create(:purchase,
                                      purchaser:,
                                      link: preorder_product,
                                      chargeable: create(:paypal_chargeable),
                                      purchase_state: "in_progress", preorder:,
                                      is_preorder_authorization: true)
      authorization_purchase.process!
      authorization_purchase.mark_preorder_authorization_successful!
      preorder.mark_authorization_successful!

      preorder_product_2 = create(:product, user: @user, price_cents: 1000, is_in_preorder_state: true)
      create(:preorder_link, link: preorder_product_2, release_at: 5.days.from_now)
      preorder = create(:preorder, preorder_link: preorder_product_2.preorder_link)
      authorization_purchase = create(:purchase,
                                      link: preorder_product_2,
                                      chargeable: create(:native_paypal_chargeable),
                                      purchase_state: "in_progress",
                                      preorder:,
                                      is_preorder_authorization: true)
      authorization_purchase.process!
      authorization_purchase.mark_preorder_authorization_successful!
      preorder.mark_authorization_successful!

      expect(@user.active_preorders?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_preorders?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_preorders?(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)).to be false

      purchaser.credit_card = create(:credit_card, chargeable: create(:paypal_chargeable), user: purchaser)
      purchaser.save!

      expect(@user.active_preorders?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_preorders?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_preorders?(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)).to be false

      preorder_product.is_in_preorder_state = false
      preorder_product.save!

      expect(@user.active_preorders?(charge_processor_id: StripeChargeProcessor.charge_processor_id)).to be false
      expect(@user.active_preorders?(charge_processor_id: PaypalChargeProcessor.charge_processor_id)).to be true
      expect(@user.active_preorders?(charge_processor_id: BraintreeChargeProcessor.charge_processor_id)).to be false
    end
  end

  describe "#first_sale_created_at_for_analytics" do
    it "returns the created_at of the first sale considered in analytics" do
      product = create(:product, user: @user)

      expect(@user.first_sale_created_at_for_analytics).to eq(nil)

      create(:failed_purchase, link: product, created_at: "2021-01-01")
      create(:purchase, link: product, created_at: "2021-01-05")
      expect(@user.first_sale_created_at_for_analytics).to eq(Time.zone.local(2021, 1, 5))

      create(:preorder_authorization_purchase, link: product, created_at: "2021-01-04")
      expect(@user.first_sale_created_at_for_analytics).to eq(Time.zone.local(2021, 1, 4))

      create(:purchase, purchase_state: "preorder_concluded_successfully", link: product, created_at: "2021-01-03")
      expect(@user.first_sale_created_at_for_analytics).to eq(Time.zone.local(2021, 1, 3))
    end
  end

  describe "#archived_products_count" do
    context "when the user has no products" do
      it "returns 0" do
        expect(@user.archived_products_count).to eq(0)
      end
    end

    context "when the user has products" do
      before do
        create(:product, user: @user)
        create(:product, user: @user)
        create(:product, user: @user, archived: true)
        create(:product, user: @user, deleted_at: Time.current, archived: true)
      end

      it "counts the number of visible archived products" do
        expect(@user.archived_products_count).to eq(1)
      end
    end
  end

  describe "#lost_chargebacks", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    context "when the user has sales" do
      before do
        create(:purchase, link: create(:product, price_cents: 5000, user: @user))
        create(:disputed_purchase, link: create(:product, price_cents: 1000, user: @user))
      end

      it "returns the correct volume and count percentages" do
        result = @user.lost_chargebacks
        expect(result[:volume]).to eq("16.7%") # (disputed_volume / all_volume) == (10 / (50 + 10))
        expect(result[:count]).to eq("50.0%") # (disputed_count / all_count) == (1 / (1 + 1))
      end
    end

    context "when the user has no sales" do
      it "returns 'NA' for both volume and count" do
        result = @user.lost_chargebacks
        expect(result[:volume]).to eq("NA")
        expect(result[:count]).to eq("NA")
      end
    end

    context "when the user has no paid sales" do
      before do
        create(:purchase, link: create(:product, price_cents: 0, user: @user))
      end

      it "returns '0.0%' for count and 'NA' for volume" do
        result = @user.lost_chargebacks
        expect(result[:volume]).to eq("NA")
        expect(result[:count]).to eq("0.0%")
      end
    end
  end

  describe "#all_sales_count" do
    it "returns the number of unique customers" do
      product_1 = create(:product, user: @user)
      product_2 = create(:product, user: @user)
      create(:purchase, link: product_1, email: "john@example.com")
      create(:purchase, link: product_1, email: "sarah@example.com")
      create(:purchase, link: product_2, email: "john@example.com")
      create(:purchase, link: product_1, email: "paul@example.com")
      create(:purchase, link: product_1, email: "george@example.com", stripe_refunded: true)
      create(:purchase)
      index_model_records(Purchase)

      expect(@user.all_sales_count).to eq(4)
    end
  end

  describe "#active_members_count" do
    it "returns the non-unique number of members for all products" do
      product_1 = create(:membership_product, user: @user)
      product_2 = create(:membership_product, user: @user)
      create(:membership_product, user: @user, deleted_at: Time.current)
      create(:membership_product)

      expect(Link).to receive(:successful_sales_count).with(products: [product_1.id, product_2.id]).and_return(456)

      expect(@user.active_members_count).to eq(456)
    end

    describe "#monthly_recurring_revenue" do
      it "returns the monthly recurring revenue of all products" do
        product_1 = create(:membership_product, user: @user)
        product_2 = create(:membership_product, user: @user)
        create(:membership_product, user: @user, deleted_at: Time.current)
        create(:membership_product)

        expect(Link).to receive(:monthly_recurring_revenue).with(products: [product_1.id, product_2.id]).and_return(456)

        expect(@user.monthly_recurring_revenue).to eq(456)
      end
    end
  end
end
