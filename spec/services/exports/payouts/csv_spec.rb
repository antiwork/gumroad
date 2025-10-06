# frozen_string_literal: true

require "spec_helper"

describe Exports::Payouts::Csv, :vcr do
  describe "perform" do
    let!(:now) { Time.current }
    let!(:payout_date) { 1.week.ago }
    let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

    before do
      @seller = create :named_user
      @another_seller = create :named_user
      @direct_affiliate = create :direct_affiliate, affiliate_user: @seller, seller: @another_seller
      base_past_date = 1.month.ago
      allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)

      travel_to(base_past_date) do
        @product = create :product, user: @seller, name: "Hunting Capybaras For Fun And Profit", price_cents: 1000
        @affiliate_product = create :product, user: @another_seller, name: "Some Affiliate Product", price_cents: 1000
      end

      travel_to(base_past_date - 2.days) do
        @purchase_to_chargeback = create_purchase price_cents: 1000, seller: @seller, link: @product

        event = OpenStruct.new(created_at: 1.day.ago, extras: {}, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_chargeback.total_transaction_cents))
        allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
        @purchase_to_chargeback.handle_event_dispute_formalized!(event)
      end

      travel_to(base_past_date) do
        @regular_purchase = create_purchase price_cents: 1000, seller: @seller, link: @product
        @paypal_purchase = create_purchase price_cents: 1000, seller: @seller, link: @product,
                                           charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                           chargeable: create(:native_paypal_chargeable),
                                           merchant_account: create(:merchant_account_paypal, user: @seller,
                                                                                              charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                                                              country: "GB", currency: "gbp")
        @paypal_purchase.update!(affiliate_credit_cents: 200)

        @purchase_with_tax = create_purchase price_cents: 1000, seller: @seller, link: @product, tax_cents: 200
        @purchase_with_gumroad_tax = create_purchase price_cents: 1000, seller: @seller, link: @product, gumroad_tax_cents: 180
        @purchase_with_affiliate_1 = create_purchase price_cents: 1000, seller: @another_seller, link: @affiliate_product, affiliate: @direct_affiliate
        @purchase_to_refund = create_purchase price_cents: 1000, seller: @seller, link: @product
        @user_credit = Credit.create_for_credit!(user: @seller, amount_cents: 1000, crediting_user: create(:user))
      end

      travel_to(base_past_date + 1.day) do
        @purchase_to_refund.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_refund.total_transaction_cents), @seller)
        @purchase_to_refund.reload
      end

      travel_to(base_past_date) do
        @purchase_to_refund_partially = create(:purchase_in_progress, price_cents: 1000, seller: @seller, link: @product, chargeable: create(:chargeable))
        @purchase_to_refund_partially.process!
        @purchase_to_refund_partially.update_balance_and_mark_successful!
      end

      travel_to(base_past_date + 1.day) do
        @purchase_to_refund_partially.refund_and_save!(@seller.id, amount_cents: 350)
        @purchase_to_refund_partially.reload
      end

      travel_to(base_past_date) do
        @purchase_to_refund_from_years_ago = create_purchase price_cents: 1000, seller: @seller, link: @product
      end

      travel_to(base_past_date + 1.day) do
        @purchase_to_refund_from_years_ago.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase_to_refund.total_transaction_cents), @seller)
        @purchase_to_refund_from_years_ago.refunds.first.balance_transactions.destroy_all
        @purchase_to_refund_from_years_ago.reload
      end

      travel_to(base_past_date) do
        bt = BalanceTransaction::Amount.new(
          currency: @regular_purchase.link.price_currency_type,
          gross_cents: @regular_purchase.payment_cents,
          net_cents: @regular_purchase.payment_cents)

        @credit_for_dispute_won = Credit.create_for_dispute_won!(user: @seller,
                                                                 merchant_account: MerchantAccount.gumroad(PaypalChargeProcessor::DISPLAY_NAME),
                                                                 dispute: create(:dispute, purchase: @regular_purchase),
                                                                 chargedback_purchase: @regular_purchase,
                                                                 balance_transaction_issued_amount: bt,
                                                                 balance_transaction_holding_amount: bt)
      end

      @payout = create_payout(payout_date, payout_processor_type, @seller)
    end

    it "shows all activity related to the payout" do
      csv = Exports::Payouts::Csv.new(payment_id: @payout.id).perform
      parsed_csv = CSV.parse(csv)
      expected = [
        Exports::Payouts::Csv::HEADERS,
        ["Chargeback", @purchase_to_chargeback.chargeback_date.to_date.to_s, @purchase_to_chargeback.external_id, @purchase_to_chargeback.link.name, @purchase_to_chargeback.full_name, @purchase_to_chargeback.purchaser_email_or_email, "-0.0", "-0.0", "-10.0", "-2.09", "-7.91"],
        ["Sale", @purchase_to_chargeback.succeeded_at.to_date.to_s, @purchase_to_chargeback.external_id, @purchase_to_chargeback.link.name, @purchase_to_chargeback.full_name, @purchase_to_chargeback.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Credit", @user_credit.balance.date.to_s, "", "", "", "", "", "", "10.0", "", "10.0"],
        ["Sale", @regular_purchase.succeeded_at.to_date.to_s, @regular_purchase.external_id, @regular_purchase.link.name, @regular_purchase.full_name, @regular_purchase.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_with_tax.succeeded_at.to_date.to_s, @purchase_with_tax.external_id, @purchase_with_tax.link.name, @purchase_with_tax.full_name, @purchase_with_tax.purchaser_email_or_email, "2.0", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_with_gumroad_tax.succeeded_at.to_date.to_s, @purchase_with_gumroad_tax.external_id, @purchase_with_gumroad_tax.link.name, @purchase_with_gumroad_tax.full_name, @purchase_with_gumroad_tax.purchaser_email_or_email, "1.8", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_to_refund.succeeded_at.to_date.to_s, @purchase_to_refund.external_id, @purchase_to_refund.link.name, @purchase_to_refund.full_name, @purchase_to_refund.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_to_refund_partially.succeeded_at.to_date.to_s, @purchase_to_refund_partially.external_id, @purchase_to_refund_partially.link.name, @purchase_to_refund_partially.full_name, @purchase_to_refund_partially.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_to_refund_from_years_ago.succeeded_at.to_date.to_s, @purchase_to_refund_from_years_ago.external_id, @purchase_to_refund_from_years_ago.link.name, @purchase_to_refund_from_years_ago.full_name, @purchase_to_refund_from_years_ago.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Affiliate Credit", @purchase_with_tax.succeeded_at.to_date.to_s, "", "", "", "", "", "", "0.23", "", "0.23"],
        ["Credit", @credit_for_dispute_won.balance.date.to_s, @regular_purchase.external_id, "", "", "", "", "", "7.91", "", "7.91"],
        ["Sale", @paypal_purchase.succeeded_at.to_date.to_s, @paypal_purchase.external_id, @paypal_purchase.link.name, @paypal_purchase.full_name, @paypal_purchase.purchaser_email_or_email, "0.0", "0.0", "10.0", "1.5", "8.5"],
        ["PayPal Connect Affiliate Fees", @paypal_purchase.succeeded_at.to_date.to_s, "", "", "", "", "", "", "-2.0", "", "-2.0"],
        ["Full Refund", (@purchase_to_refund.succeeded_at + 1.day).to_date.to_s, @purchase_to_refund.external_id, @purchase_to_refund.link.name, @purchase_to_refund.full_name, @purchase_to_refund.purchaser_email_or_email, "-0.0", "-0.0", "-10.0", "-1.5", "-8.5"],
        ["Partial Refund", (@purchase_to_refund_partially.succeeded_at + 1.day).to_date.to_s, @purchase_to_refund_partially.external_id, @purchase_to_refund_partially.link.name, @purchase_to_refund_partially.full_name, @purchase_to_refund_partially.purchaser_email_or_email, "-0.0", "-0.0", "-3.5", "-0.55", "-2.95"],
        ["Full Refund", (@purchase_to_refund_from_years_ago.succeeded_at + 1.day).to_date.to_s, @purchase_to_refund_from_years_ago.external_id, @purchase_to_refund_from_years_ago.link.name, @purchase_to_refund_from_years_ago.full_name, @purchase_to_refund_from_years_ago.purchaser_email_or_email, "-0.0", "-0.0", "-10.0", "-1.5", "-8.5"],
        ["PayPal Payouts", @payout.payout_period_end_date.to_s, "", "", "", "", "", "", "-6.5", "", "-6.5"],
        ["Payout Fee", @payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "0.92", "-0.92"],
        ["Totals", nil, nil, nil, nil, nil, "3.8", "0.0", "56.14", "11.41", "44.73"]
      ]

      expect(parsed_csv).to eq(expected)
    end

    describe "Technical Adjustment entries" do
      it "does not add entry for non-usd payment currency" do
        @payout.amount_cents = @payout.amount_cents + 100
        @payout.currency = Currency::GBP
        @payout.save!
        csv = Exports::Payouts::Csv.new(payment_id: @payout.id).perform
        parsed_csv = CSV.parse(csv)
        expect(parsed_csv).not_to include(["Technical Adjustment", @payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "", "1.0"])
      end

      it "add entry for usd payment currency" do
        @payout.amount_cents = @payout.amount_cents + 100
        @payout.save!
        csv = Exports::Payouts::Csv.new(payment_id: @payout.id).perform
        parsed_csv = CSV.parse(csv)
        expect(parsed_csv).to include(["Technical Adjustment", @payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "", "1.0"])
      end
    end
  end

  describe "affiliate fees from Stripe Connect sales" do
    it "correctly adds the affiliate fee entries from Stripe Connect sales" do
      seller = create :user
      direct_affiliate = create(:direct_affiliate, affiliate_user: create(:user), seller:)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: seller, charge_processor_merchant_id: "acct_1MeFbmKQKir5qdfM")

      travel_to(1.month.ago) do
        affiliate_product = create :product, user: seller, name: "Some Affiliate Product", price_cents: 15000
        create_purchase price_cents: 1000, seller:, link: affiliate_product
        create_purchase price_cents: 1000, seller:, link: affiliate_product,
                        affiliate: direct_affiliate, merchant_account: stripe_connect_account
      end

      regular_purchase = Purchase.where.not(merchant_account_id: stripe_connect_account.id).last
      stripe_connect_purchase = Purchase.where(merchant_account_id: stripe_connect_account.id).last

      travel_to(10.days.ago) do
        stripe_connect_purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 7500), seller.id)
      end

      payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, seller)

      csv = Exports::Payouts::Csv.new(payment_id: payout.id).perform
      parsed_csv = CSV.parse(csv)
      expect(parsed_csv).to match_array [
        Exports::Payouts::Csv::HEADERS,
        ["Sale", regular_purchase.succeeded_at.to_date.to_s, regular_purchase.external_id, regular_purchase.link.name, regular_purchase.full_name, regular_purchase.purchaser_email_or_email, "0.0", "0.0", "150.0", "20.15", "129.85"],
        ["Sale", stripe_connect_purchase.succeeded_at.to_date.to_s, stripe_connect_purchase.external_id, stripe_connect_purchase.link.name, stripe_connect_purchase.full_name, stripe_connect_purchase.purchaser_email_or_email, "0.0", "0.0", "150.0", "15.5", "134.5"],
        ["Stripe Connect Affiliate Fees", stripe_connect_purchase.succeeded_at.to_date.to_s, "", "", "", "", "", "", "-4.03", "", "-4.03"],
        ["Stripe Connect Refund", 10.days.ago.to_date.to_s, stripe_connect_purchase.external_id, stripe_connect_purchase.link.name, stripe_connect_purchase.full_name, stripe_connect_purchase.purchaser_email_or_email, "-0.0", "-0.0", "-75.0", "7.75", "-67.25"],
        ["Stripe Connect Affiliate Fees", 10.days.ago.to_date.to_s, "", "", "", "", "", "", "2.02", "", "2.02"],
        ["Stripe Connect Payouts", payout.payout_period_end_date.to_date.to_s, "", "", "", "", "", "", "-65.24", "", "-65.24"],
        ["Payout Fee", payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "2.6", "-2.6"],
        ["Totals", nil, nil, nil, nil, nil, "0.0", "0.0", "157.75", "46.0", "127.25"]
      ]
    end
  end

  describe "affiliate credits involving several balances" do
    let!(:now) { Time.current }
    let!(:payout_date) { 1.week.ago }
    let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

    before do
      @seller = create :user
      @another_seller = create :user
      @direct_affiliate = create :direct_affiliate, affiliate_user: @seller, seller: @another_seller

      travel_to(1.month.ago) do
        @affiliate_product = create :product, user: @another_seller, name: "Some Affiliate Product", price_cents: 1000
        @affiliate_product_2 = create :product, user: @another_seller, name: "Some Affiliate Product", price_cents: 15000
      end

      travel_to(1.month.ago + 1.day) do
        @from_previous_payout = create_purchase price_cents: 1000, seller: @another_seller, link: @affiliate_product, affiliate: @direct_affiliate
      end

      travel_to(1.month.ago + 2.day) do
        create_payout(Time.current, payout_processor_type, @seller)
      end

      travel_to(1.month.ago + 9.day) do
        @from_this_payout = create_purchase price_cents: 15000, seller: @another_seller, link: @affiliate_product_2, affiliate: @direct_affiliate

        @from_previous_payout.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @from_previous_payout.total_transaction_cents), @seller)
        @from_previous_payout.reload
      end

      travel_to(1.month.ago + 18.day) do
        @payout = create_payout(payout_date, payout_processor_type, @seller)
      end
    end

    it "takes refunded credit into account, even if actual credit happened in a different payout" do
      csv = Exports::Payouts::Csv.new(payment_id: @payout.id).perform
      parsed_csv = CSV.parse(csv)
      # +3.96 for from_this_payout credit
      # -0.30 for from_previous_payout refund
      expect(parsed_csv).to eq [
        Exports::Payouts::Csv::HEADERS,
        ["Affiliate Credit", @from_this_payout.succeeded_at.to_date.to_s, "", "", "", "", "", "", "3.66", "", "3.66"],
        ["Payout Fee", @payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "0.08", "-0.08"],
        ["Totals", nil, nil, nil, nil, nil, "0.0", "0.0", "3.66", "0.08", "3.58"]
      ]
    end
  end

  def create_payout(payout_date, processor_type, user)
    payment, _ = Payouts.create_payment(payout_date, processor_type, user)
    payment.update(correlation_id: "12345")
    payment.txn_id = 123
    payment.mark_completed!
    payment
  end

  def create_purchase(**attrs)
    purchase = create :purchase, **attrs, card_type: CardType::PAYPAL, purchase_state: "in_progress"
    purchase.process!
    purchase.update_balance_and_mark_successful!
    if attrs[:tax_cents]
      purchase.tax_cents = attrs[:tax_cents]
      purchase.save
    end
    if attrs[:gumroad_tax_cents]
      purchase.gumroad_tax_cents = attrs[:gumroad_tax_cents]
      purchase.save
    end
    purchase
  end
end
