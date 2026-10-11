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
      # These payout fixtures are not representative of the seller's chargeback rate.
      allow_any_instance_of(Purchase).to receive(:pause_payouts_for_seller_based_on_chargeback_rate!)
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
      csv = Exports::Payouts::Csv.new(payment: @payout).perform
      parsed_csv = CSV.parse(csv)
      expected = [
        Exports::Payouts::Csv::HEADERS,
        ["Chargeback", @purchase_to_chargeback.chargeback_date.to_date.to_s, csv_safe(@purchase_to_chargeback.external_id), @purchase_to_chargeback.link.name, @purchase_to_chargeback.full_name, @purchase_to_chargeback.purchaser_email_or_email, "-0.0", "-0.0", "-10.0", "-2.09", "-7.91"],
        ["Sale", @purchase_to_chargeback.succeeded_at.to_date.to_s, csv_safe(@purchase_to_chargeback.external_id), @purchase_to_chargeback.link.name, @purchase_to_chargeback.full_name, @purchase_to_chargeback.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Credit", @user_credit.balance.date.to_s, "", "", "", "", "", "", "10.0", "", "10.0"],
        ["Sale", @regular_purchase.succeeded_at.to_date.to_s, csv_safe(@regular_purchase.external_id), @regular_purchase.link.name, @regular_purchase.full_name, @regular_purchase.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_with_tax.succeeded_at.to_date.to_s, csv_safe(@purchase_with_tax.external_id), @purchase_with_tax.link.name, @purchase_with_tax.full_name, @purchase_with_tax.purchaser_email_or_email, "2.0", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_with_gumroad_tax.succeeded_at.to_date.to_s, csv_safe(@purchase_with_gumroad_tax.external_id), @purchase_with_gumroad_tax.link.name, @purchase_with_gumroad_tax.full_name, @purchase_with_gumroad_tax.purchaser_email_or_email, "1.8", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_to_refund.succeeded_at.to_date.to_s, csv_safe(@purchase_to_refund.external_id), @purchase_to_refund.link.name, @purchase_to_refund.full_name, @purchase_to_refund.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_to_refund_partially.succeeded_at.to_date.to_s, csv_safe(@purchase_to_refund_partially.external_id), @purchase_to_refund_partially.link.name, @purchase_to_refund_partially.full_name, @purchase_to_refund_partially.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Sale", @purchase_to_refund_from_years_ago.succeeded_at.to_date.to_s, csv_safe(@purchase_to_refund_from_years_ago.external_id), @purchase_to_refund_from_years_ago.link.name, @purchase_to_refund_from_years_ago.full_name, @purchase_to_refund_from_years_ago.purchaser_email_or_email, "0.0", "0.0", "10.0", "2.09", "7.91"],
        ["Affiliate Credit", @purchase_with_tax.succeeded_at.to_date.to_s, "", "", "", "", "", "", "0.23", "", "0.23"],
        ["Credit", @credit_for_dispute_won.balance.date.to_s, csv_safe(@regular_purchase.external_id), "", "", "", "", "", "7.91", "", "7.91"],
        ["Sale", @paypal_purchase.succeeded_at.to_date.to_s, csv_safe(@paypal_purchase.external_id), @paypal_purchase.link.name, @paypal_purchase.full_name, @paypal_purchase.purchaser_email_or_email, "0.0", "0.0", "10.0", "1.5", "8.5"],
        ["PayPal Connect Affiliate Fees", @paypal_purchase.succeeded_at.to_date.to_s, "", "", "", "", "", "", "-2.0", "", "-2.0"],
        ["Full Refund", (@purchase_to_refund.succeeded_at + 1.day).to_date.to_s, csv_safe(@purchase_to_refund.external_id), @purchase_to_refund.link.name, @purchase_to_refund.full_name, @purchase_to_refund.purchaser_email_or_email, "-0.0", "-0.0", "-10.0", "-1.5", "-8.5"],
        ["Partial Refund", (@purchase_to_refund_partially.succeeded_at + 1.day).to_date.to_s, csv_safe(@purchase_to_refund_partially.external_id), @purchase_to_refund_partially.link.name, @purchase_to_refund_partially.full_name, @purchase_to_refund_partially.purchaser_email_or_email, "-0.0", "-0.0", "-3.5", "-0.55", "-2.95"],
        ["Full Refund", (@purchase_to_refund_from_years_ago.succeeded_at + 1.day).to_date.to_s, csv_safe(@purchase_to_refund_from_years_ago.external_id), @purchase_to_refund_from_years_ago.link.name, @purchase_to_refund_from_years_ago.full_name, @purchase_to_refund_from_years_ago.purchaser_email_or_email, "-0.0", "-0.0", "-10.0", "-1.5", "-8.5"],
        ["PayPal Payouts", @payout.payout_period_end_date.to_s, "", Exports::Payouts::Csv::PAYPAL_PAYOUTS_NOTE, "", "", "", "", "-6.5", "", "-6.5"],
        ["Payout Fee", @payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "0.92", "-0.92"],
        [Exports::Payouts::Csv::CARD_SALES_SUBTOTAL_HEADING, nil, nil, nil, nil, nil, "3.8", "0.0", "54.64", "9.91", "44.73"],
        [Exports::Payouts::Csv::PAYPAL_SALES_SUBTOTAL_HEADING, nil, nil, nil, nil, nil, "0.0", "0.0", "1.5", "1.5", "0.0"],
        ["Totals", nil, nil, nil, nil, nil, "3.8", "0.0", "56.14", "11.41", "44.73"]
      ]

      expect(parsed_csv).to eq(expected)
    end

    describe "Technical Adjustment entries" do
      it "does not add entry for non-usd payment currency" do
        @payout.amount_cents = @payout.amount_cents + 100
        @payout.currency = Currency::GBP
        @payout.save!
        csv = Exports::Payouts::Csv.new(payment: @payout).perform
        parsed_csv = CSV.parse(csv)
        expect(parsed_csv).not_to include(["Technical Adjustment", @payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "", "1.0"])
      end

      it "add entry for usd payment currency" do
        @payout.amount_cents = @payout.amount_cents + 100
        @payout.save!
        csv = Exports::Payouts::Csv.new(payment: @payout).perform
        parsed_csv = CSV.parse(csv)
        expect(parsed_csv).to include(["Technical Adjustment", @payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "", "1.0"])
      end
    end
  end

  describe "affiliate fees from Stripe Connect sales" do
    it "correctly adds the affiliate fee entries from Stripe Connect sales" do
      # The refund is created inside `travel_to(10.days.ago)` while the expected CSV row
      # re-reads `10.days.ago.to_date` at assertion time; crossing midnight between the two
      # skews the expected date by a day.
      travel_to(Time.current.midday)

      seller = create :user
      direct_affiliate = create(:direct_affiliate, affiliate_user: create(:user), seller:)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: seller, charge_processor_merchant_id: "acct_1SOb0DEwFhlcVS6d")

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

      csv = Exports::Payouts::Csv.new(payment: payout).perform
      parsed_csv = CSV.parse(csv)
      expect(parsed_csv).to match_array [
        Exports::Payouts::Csv::HEADERS,
        ["Sale", regular_purchase.succeeded_at.to_date.to_s, csv_safe(regular_purchase.external_id), regular_purchase.link.name, regular_purchase.full_name, regular_purchase.purchaser_email_or_email, "0.0", "0.0", "150.0", "20.15", "129.85"],
        ["Sale", stripe_connect_purchase.succeeded_at.to_date.to_s, csv_safe(stripe_connect_purchase.external_id), stripe_connect_purchase.link.name, stripe_connect_purchase.full_name, stripe_connect_purchase.purchaser_email_or_email, "0.0", "0.0", "150.0", "15.5", "134.5"],
        ["Stripe Connect Affiliate Fees", stripe_connect_purchase.succeeded_at.to_date.to_s, "", "", "", "", "", "", "-4.03", "", "-4.03"],
        ["Stripe Connect Refund", 10.days.ago.to_date.to_s, csv_safe(stripe_connect_purchase.external_id), stripe_connect_purchase.link.name, stripe_connect_purchase.full_name, stripe_connect_purchase.purchaser_email_or_email, "-0.0", "-0.0", "-75.0", "7.75", "-67.25"],
        ["Stripe Connect Affiliate Fees", 10.days.ago.to_date.to_s, "", "", "", "", "", "", "2.02", "", "2.02"],
        ["Stripe Connect Payouts", payout.payout_period_end_date.to_date.to_s, "", Exports::Payouts::Csv::STRIPE_CONNECT_PAYOUTS_NOTE, "", "", "", "", "-65.24", "", "-65.24"],
        ["Payout Fee", payout.payout_period_end_date.to_s, "", "", "", "", "", "", "", "2.6", "-2.6"],
        [Exports::Payouts::Csv::CARD_SALES_SUBTOTAL_HEADING, nil, nil, nil, nil, nil, "0.0", "0.0", "150.0", "22.75", "127.25"],
        [Exports::Payouts::Csv::STRIPE_CONNECT_SALES_SUBTOTAL_HEADING, nil, nil, nil, nil, nil, "0.0", "0.0", "7.75", "23.25", "0.0"],
        ["Totals", nil, nil, nil, nil, nil, "0.0", "0.0", "157.75", "46.0", "127.25"]
      ]
    end
  end

  # Regression for gumroad-private#1028: sellers re-parse this CSV with Excel's
  # "Text to Columns" (comma delimiter), which splits inside quoted fields, and
  # Windows Excel reads non-ASCII bytes in this BOM-less UTF-8 file as cp1252
  # mojibake. Every free-text label we add must therefore be ASCII-only and
  # comma-free.
  describe "subtotal headings and deduction notes" do
    it "keeps all label constants ASCII-only and comma-free" do
      [
        Exports::Payouts::Csv::CARD_SALES_SUBTOTAL_HEADING,
        Exports::Payouts::Csv::PAYPAL_SALES_SUBTOTAL_HEADING,
        Exports::Payouts::Csv::STRIPE_CONNECT_SALES_SUBTOTAL_HEADING,
        Exports::Payouts::Csv::PAYPAL_PAYOUTS_NOTE,
        Exports::Payouts::Csv::STRIPE_CONNECT_PAYOUTS_NOTE,
      ].each do |label|
        expect(label).to match(/\A[[:ascii:]]+\z/), "expected ASCII-only label, got: #{label}"
        expect(label).not_to include(","), "expected comma-free label, got: #{label}"
      end
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
      csv = Exports::Payouts::Csv.new(payment: @payout).perform
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

  describe "seller's affiliate commission on refunded sales" do
    before do
      @seller = create :user
      direct_affiliate = create :direct_affiliate, affiliate_user: create(:user), seller: @seller

      travel_to(1.month.ago) do
        product = create :product, user: @seller, price_cents: 1000
        @kept_sale = create_purchase price_cents: 1000, seller: @seller, link: product, affiliate: direct_affiliate
        @fully_refunded_sale = create_purchase price_cents: 1000, seller: @seller, link: product, affiliate: direct_affiliate
        @partially_refunded_sale = create_purchase price_cents: 1000, seller: @seller, link: product, affiliate: direct_affiliate
      end

      travel_to(1.month.ago + 1.day) do
        @fully_refunded_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @fully_refunded_sale.total_transaction_cents), @seller.id)
        @partially_refunded_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 350), @seller.id)
        @partially_refunded_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 200), @seller.id)
      end

      @payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, @seller)
    end

    it "gives the commission back only for full refunds" do
      expect(@partially_refunded_sale.reload.affiliate_credit_cents).to be_positive

      parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: @payout).perform)
      types = parsed_csv.map(&:first)
      affiliate_net = parsed_csv.select { |row| row.first == "Affiliate Credit" }.sum { |row| row.last.to_f }

      expect(types.count("Full Refund")).to eq(1)
      expect(types.count("Partial Refund")).to eq(2)
      expect(affiliate_net).to be_within(0.001).of(-(@kept_sale.affiliate_credit_cents + @partially_refunded_sale.affiliate_credit_cents) / 100.0)
      expect(types).not_to include("Technical Adjustment")
      expect(parsed_csv.last.last.to_f).to eq(@payout.amount_cents / 100.0)
    end
  end

  describe "affiliate credit clawed back by several partial refunds" do
    before do
      @seller = create :user
      another_seller = create :user
      direct_affiliate = create :direct_affiliate, affiliate_user: @seller, seller: another_seller

      travel_to(1.month.ago) do
        @own_product = create :product, user: @seller, price_cents: 1000
        affiliate_product = create :product, user: another_seller, price_cents: 15000
        @affiliated_sale = create_purchase price_cents: 15000, seller: another_seller, link: affiliate_product, affiliate: direct_affiliate
      end

      travel_to(1.month.ago + 1.day) do
        @affiliated_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 3000), another_seller.id)
        @affiliated_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 2000), another_seller.id)
      end

      travel_to(1.month.ago + 2.days) do
        @first_payout = create_payout(Time.current, PayoutProcessorType::PAYPAL, @seller)
      end

      travel_to(1.month.ago + 9.days) do
        create_purchase price_cents: 1000, seller: @seller, link: @own_product
        @affiliated_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 4000), another_seller.id)
      end

      travel_to(1.month.ago + 18.days) do
        @second_payout = create_payout(Time.current, PayoutProcessorType::PAYPAL, @seller)
      end
    end

    it "deducts each clawback in the payout whose balance it debited" do
      affiliate_credit = @affiliated_sale.reload.affiliate_credit
      first_clawbacks, second_clawbacks = affiliate_credit.affiliate_partial_refunds.partition do |partial_refund|
        @first_payout.balances.ids.include?(partial_refund.balance_id)
      end
      expect(first_clawbacks.size).to eq(2)
      expect(second_clawbacks.size).to eq(1)
      expect(@second_payout.balances.ids).to include(affiliate_credit.affiliate_credit_refund_balance_id)

      [
        [@first_payout, affiliate_credit.amount_cents - first_clawbacks.sum(&:amount_cents)],
        [@second_payout, -second_clawbacks.sum(&:amount_cents)],
      ].each do |payout, expected_affiliate_cents|
        parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: payout).perform)
        affiliate_net = parsed_csv.select { |row| row.first == "Affiliate Credit" }.sum { |row| row.last.to_f }

        expect(affiliate_net).to be_within(0.001).of(expected_affiliate_cents / 100.0)
        expect(parsed_csv.map(&:first)).not_to include("Technical Adjustment")
        expect(parsed_csv.last.last.to_f).to eq(payout.amount_cents / 100.0)
      end
    end
  end

  describe "affiliate credit on charged-back sales" do
    before do
      allow_any_instance_of(Purchase).to receive(:pause_payouts_for_seller_based_on_chargeback_rate!)
      allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)

      @seller = create :user
      another_seller = create :user
      @affiliate_user = create :user
      direct_affiliate = create :direct_affiliate, affiliate_user: @affiliate_user, seller: @seller
      another_direct_affiliate = create :direct_affiliate, affiliate_user: @affiliate_user, seller: another_seller

      travel_to(1.month.ago) do
        product = create :product, user: @seller, price_cents: 1000
        @kept_sale = create_purchase seller: @seller, link: product, affiliate: direct_affiliate
        @fully_charged_back_sale = create_purchase seller: @seller, link: product, affiliate: direct_affiliate
        @charged_back_after_partial_refund_sale = create_purchase seller: another_seller, link: create(:product, user: another_seller, price_cents: 1000), affiliate: another_direct_affiliate
        create_purchase seller: @seller, link: create(:product, user: @seller, price_cents: 100_00)
        create_purchase seller: @affiliate_user, link: create(:product, user: @affiliate_user, price_cents: 1000)
      end

      travel_to(1.month.ago + 1.day) do
        @charged_back_after_partial_refund_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 300), another_seller.id)
      end

      travel_to(1.month.ago + 2.days) do
        [@fully_charged_back_sale, @charged_back_after_partial_refund_sale.reload].each do |purchase|
          event = OpenStruct.new(created_at: Time.current, extras: {}, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents))
          purchase.handle_event_dispute_formalized!(event)
        end
      end

      @seller_payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, @seller)
      @affiliate_payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, @affiliate_user)
    end

    it "gives the seller the whole commission back for a full chargeback" do
      parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: @seller_payout).perform)
      chargeback_row = parsed_csv.find { |row| row.first == "Chargeback" && row.third == @fully_charged_back_sale.external_id }

      expect(chargeback_row.last.to_f).to eq(-@fully_charged_back_sale.net_total)
      expect(affiliate_net(parsed_csv)).to be_within(0.001).of(-@kept_sale.affiliate_credit_cents / 100.0)
      expect(parsed_csv.map(&:first)).not_to include("Technical Adjustment")
      expect(parsed_csv.last.last.to_f).to eq(@seller_payout.amount_cents / 100.0)
    end

    it "deducts the whole credit for a full chargeback and each clawback after a partial refund" do
      partial_credit = @charged_back_after_partial_refund_sale.reload.affiliate_credit
      expect(@fully_charged_back_sale.affiliate_credit.affiliate_partial_refunds).to be_empty
      expect(partial_credit.affiliate_partial_refunds.size).to eq(2)
      expect(@affiliate_payout.balances.ids).to include(@fully_charged_back_sale.affiliate_credit.affiliate_credit_chargeback_balance_id,
                                                        partial_credit.affiliate_credit_chargeback_balance_id)

      parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: @affiliate_payout).perform)
      expected_cents = @kept_sale.affiliate_credit_cents + partial_credit.amount_cents - partial_credit.affiliate_partial_refunds.sum(&:amount_cents)

      expect(affiliate_net(parsed_csv)).to be_within(0.001).of(expected_cents / 100.0)
      expect(expected_cents).to eq(affiliate_ledger_cents(@affiliate_payout))
      expect(parsed_csv.map(&:first)).not_to include("Technical Adjustment")
      expect(parsed_csv.last.last.to_f).to eq(@affiliate_payout.amount_cents / 100.0)
    end
  end

  describe "whole affiliate clawback after a partial one" do
    # With the seller bearing the affiliate fee, the last refund's rounded-up clawback equals the
    # whole credit, so it leaves no AffiliatePartialRefund row even though an earlier refund did.
    before do
      allow_any_instance_of(Purchase).to receive(:pause_payouts_for_seller_based_on_chargeback_rate!)
      allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)

      @seller = create :user, bears_affiliate_fee: true
      @affiliate_user = create :user
      direct_affiliate = create :direct_affiliate, affiliate_user: @affiliate_user, seller: @seller, affiliate_basis_points: 1000

      travel_to(1.month.ago) do
        @own_product = create :product, user: @affiliate_user, price_cents: 1000
        create_purchase seller: @affiliate_user, link: @own_product
        @affiliated_sale = create_purchase seller: @seller, link: create(:product, user: @seller, price_cents: 1000), affiliate: direct_affiliate
      end

      travel_to(1.month.ago + 1.day) do
        @affiliated_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 5), @seller.id)
      end
    end

    def refund_the_rest
      @affiliated_sale.reload.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @affiliated_sale.amount_refundable_cents), @seller.id)
    end

    it "deducts both clawbacks when they debit the same balance" do
      travel_to(1.month.ago + 2.days) { refund_the_rest }
      payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, @affiliate_user)

      affiliate_credit = @affiliated_sale.reload.affiliate_credit
      expect(affiliate_credit.affiliate_partial_refunds.map(&:amount_cents)).to eq([1])
      expect(payout.balances.ids).to include(affiliate_credit.affiliate_credit_refund_balance_id)

      parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: payout).perform)

      expect(affiliate_net(parsed_csv)).to eq(-0.01)
      expect(affiliate_ledger_cents(payout)).to eq(-1)
      expect(parsed_csv.map(&:first)).not_to include("Technical Adjustment")
      expect(parsed_csv.last.last.to_f).to eq(payout.amount_cents / 100.0)
    end

    it "deducts a whole chargeback clawback in the balance a partial refund also debited" do
      travel_to(1.month.ago + 2.days) do
        purchase = @affiliated_sale.reload
        event = OpenStruct.new(created_at: Time.current, extras: {}, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents))
        purchase.handle_event_dispute_formalized!(event)
      end
      payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, @affiliate_user)

      affiliate_credit = @affiliated_sale.reload.affiliate_credit
      expect(affiliate_credit.affiliate_partial_refunds.map(&:amount_cents)).to eq([1])
      expect(payout.balances.ids).to include(affiliate_credit.affiliate_credit_chargeback_balance_id)

      parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: payout).perform)

      expect(affiliate_net(parsed_csv)).to eq(-0.01)
      expect(affiliate_ledger_cents(payout)).to eq(-1)
      expect(parsed_csv.map(&:first)).not_to include("Technical Adjustment")
      expect(parsed_csv.last.last.to_f).to eq(payout.amount_cents / 100.0)
    end

    it "deducts a whole charge-level chargeback clawback in the balance a partial refund also debited" do
      allow_any_instance_of(Charge).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
      travel_to(1.month.ago + 2.days) do
        purchase = @affiliated_sale.reload
        charge = create(:charge, seller: @seller, purchases: [purchase], amount_cents: purchase.total_transaction_cents)
        event = OpenStruct.new(created_at: Time.current, extras: {}, flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents))
        charge.handle_event_dispute_formalized!(event)
      end
      payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, @affiliate_user)

      affiliate_credit = @affiliated_sale.reload.affiliate_credit
      expect(affiliate_credit.purchase.disputes).to be_empty
      expect(affiliate_credit.affiliate_partial_refunds.map(&:amount_cents)).to eq([1])
      expect(payout.balances.ids).to include(affiliate_credit.affiliate_credit_chargeback_balance_id)

      parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: payout).perform)

      expect(affiliate_net(parsed_csv)).to eq(-0.01)
      expect(affiliate_ledger_cents(payout)).to eq(-1)
      expect(parsed_csv.map(&:first)).not_to include("Technical Adjustment")
      expect(parsed_csv.last.last.to_f).to eq(payout.amount_cents / 100.0)
    end

    it "deducts the whole clawback in the later balance it debited" do
      first_payout = travel_to(1.month.ago + 2.days) { create_payout(Time.current, PayoutProcessorType::PAYPAL, @affiliate_user) }
      travel_to(1.month.ago + 9.days) do
        create_purchase seller: @affiliate_user, link: @own_product
        refund_the_rest
      end
      second_payout = travel_to(1.month.ago + 18.days) { create_payout(Time.current, PayoutProcessorType::PAYPAL, @affiliate_user) }

      affiliate_credit = @affiliated_sale.reload.affiliate_credit
      expect(first_payout.balances.ids).to include(affiliate_credit.affiliate_partial_refunds.sole.balance_id)
      expect(second_payout.balances.ids).to include(affiliate_credit.affiliate_credit_refund_balance_id)

      [[first_payout, 99], [second_payout, -100]].each do |payout, expected_cents|
        parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: payout).perform)

        expect(affiliate_net(parsed_csv)).to be_within(0.001).of(expected_cents / 100.0)
        expect(affiliate_ledger_cents(payout)).to eq(expected_cents)
        expect(parsed_csv.map(&:first)).not_to include("Technical Adjustment")
        expect(parsed_csv.last.last.to_f).to eq(payout.amount_cents / 100.0)
      end
    end
  end

  describe "failed refund of an affiliated sale" do
    before do
      @seller = create :user
      @affiliate_user = create :user
      direct_affiliate = create :direct_affiliate, affiliate_user: @affiliate_user, seller: @seller

      travel_to(1.month.ago) do
        create_purchase seller: @affiliate_user, link: create(:product, user: @affiliate_user, price_cents: 1000)
        @affiliated_sale = create_purchase seller: @seller, link: create(:product, user: @seller, price_cents: 150_00), affiliate: direct_affiliate
      end

      travel_to(1.month.ago + 1.day) do
        @affiliated_sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 3000), @seller.id)
        @affiliated_sale.reload.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 2000), @seller.id)
        Purchase::HandleFailedRefundService.new(refund: @affiliated_sale.refunds.last).perform
      end

      @payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, @affiliate_user)
    end

    it "deducts only the clawback that still stands and shows the failed one as a pair" do
      affiliate_credit = @affiliated_sale.reload.affiliate_credit
      remaining_clawback = affiliate_credit.affiliate_partial_refunds.sole
      expect(@affiliated_sale.refunds.last.balance_reversed_on_failure).to be_present
      expect(affiliate_credit.affiliate_credit_refund_balance_id).to eq(remaining_clawback.balance_id)

      parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: @payout).perform)
      failed_refund_rows = parsed_csv.select { |row| row.first.in?(["Failed Refund", "Failed Refund Reversal"]) }

      expect(affiliate_net(parsed_csv)).to be_within(0.001).of((affiliate_credit.amount_cents - remaining_clawback.amount_cents) / 100.0)
      expect(affiliate_ledger_cents(@payout)).to eq(affiliate_credit.amount_cents - remaining_clawback.amount_cents)
      expect(failed_refund_rows.map(&:first)).to contain_exactly("Failed Refund", "Failed Refund Reversal")
      expect(failed_refund_rows.sum { |row| row.last.to_f }).to eq(0)
      expect(parsed_csv.map(&:first)).not_to include("Technical Adjustment")
      expect(parsed_csv.last.last.to_f).to eq(@payout.amount_cents / 100.0)
    end
  end

  describe "non-USD payout with partially refunded affiliate sales" do
    before do
      @seller = create :user
      direct_affiliate = create :direct_affiliate, affiliate_user: create(:user), seller: @seller, affiliate_basis_points: 5000

      travel_to(1.month.ago) do
        product = create :product, user: @seller, price_cents: 100_00
        @affiliated_sales = Array.new(3) { create_purchase seller: @seller, link: product, affiliate: direct_affiliate }
        create_purchase seller: @seller, link: create(:product, user: @seller, price_cents: 50_00)
      end

      travel_to(1.month.ago + 1.day) do
        @affiliated_sales.first(2).zip([20_00, 35_00]).each do |sale, refund_cents|
          sale.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, refund_cents), @seller.id)
        end
      end

      @payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, @seller)
      @payout.update!(currency: Currency::GBP, amount_cents: 100_00, gumroad_fee_cents: nil)
    end

    it "keeps the whole commission deducted for partially refunded sales" do
      parsed_csv = CSV.parse(Exports::Payouts::Csv.new(payment: @payout).perform)
      types = parsed_csv[1...-1].map(&:first)

      expect(types.uniq).to contain_exactly("Sale", "Partial Refund", "Affiliate Credit")
      expect(affiliate_net(parsed_csv)).to be_within(0.001).of(-@affiliated_sales.sum { _1.reload.affiliate_credit_cents } / 100.0)
      expect(parsed_csv.last.first).to eq("Totals")
      expect(parsed_csv.last.last.to_f).to eq(@payout.balances.sum(:amount_cents) / 100.0)
    end
  end

  describe "failed refund reversals" do
    let!(:payout_date) { 1.week.ago }
    let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

    before do
      @seller = create :named_user

      travel_to(1.month.ago) do
        @product = create :product, user: @seller, name: "Some Product", price_cents: 1000
        @purchase = create(:purchase_in_progress, price_cents: 1000, seller: @seller, link: @product, chargeable: create(:chargeable))
        @purchase.process!
        @purchase.update_balance_and_mark_successful!
      end

      travel_to(1.month.ago + 1.day) do
        # Refund through the real refund path (fee retention, balance debits), with
        # only the processor call stubbed, then fail it: the buyer's bank returned
        # the money after Stripe accepted the refund.
        stripe_refund = double("stripe_refund", status: "pending", id: "re_export_failed_test")
        charge_refund = ChargeRefund.new
        charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
        charge_refund.id = stripe_refund.id
        charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -@purchase.total_transaction_cents)
        charge_refund.instance_variable_set(:@refund, stripe_refund)
        expect(ChargeProcessor).to receive(:refund!).and_return(charge_refund)
        expect(@purchase.refund_and_save!(create(:admin_user).id, reason: "test refund")).to eq(true)
        @failed_refund = @purchase.refunds.last

        Purchase::HandleFailedRefundService.new(refund: @failed_refund).perform
        @purchase.reload
      end

      travel_to(1.month.ago + 2.days) do
        @payout = create_payout(payout_date, payout_processor_type, @seller)
      end
    end

    it "renders the failed refund as an explicit debit + reversal pair that nets to zero" do
      csv = Exports::Payouts::Csv.new(payment: @payout).perform
      parsed_csv = CSV.parse(csv)
      types = parsed_csv.map(&:first)

      # The refund financially never happened, so it must not appear as a live refund.
      expect(types).not_to include("Full Refund", "Partial Refund")

      # Every movement is labeled, and each pair nets to zero.
      expect(types).to include("Failed Refund", "Failed Refund Reversal")
      net_total_index = Exports::Payouts::Csv::HEADERS.index("Net Total ($)")
      failed_refund_net = parsed_csv.select { |row| row.first.in?(["Failed Refund", "Failed Refund Reversal"]) }
                                    .sum { |row| row[net_total_index].to_f }
      expect(failed_refund_net).to eq(0.0)

      expect(types).to include("Failed Refund Fee Retained", "Failed Refund Fee Returned")
      fee_net = parsed_csv.select { |row| row.first.in?(["Failed Refund Fee Retained", "Failed Refund Fee Returned"]) }
                          .sum { |row| row[net_total_index].to_f }
      expect(fee_net).to eq(0.0)

      # The payout still balances: the seller keeps the full sale.
      totals_row = parsed_csv.reverse.find { |row| row.first == Exports::Payouts::Csv::TOTALS_COLUMN_NAME }
      expect(totals_row).to be_present
    end
  end

  describe "affiliate fee day loop" do
    # With no earlier completed payment the window floor falls back to
    # OLDEST_DISPLAYABLE_PAYOUT_PERIOD_END_DATE (2013-01-04), and the per-day affiliate fee
    # summaries then run 3 aggregates per processor for every calendar day since.
    it "does not run a per-calendar-day aggregate for days with no affiliate activity" do
      travel_to(Time.current.midday)

      seller = create :user
      affiliate = create(:direct_affiliate, affiliate_user: create(:user), seller:)
      stripe_connect_account = create(:merchant_account_stripe_connect, user: seller,
                                                                        charge_processor_merchant_id: "acct_1SOb0DEwFhlcVS6d")

      travel_to(1.month.ago) do
        product = create :product, user: seller, name: "Day Loop Product", price_cents: 15000
        create_purchase price_cents: 1000, seller:, link: product
        create_purchase price_cents: 1000, seller:, link: product,
                        affiliate:, merchant_account: stripe_connect_account
      end

      payout = create_payout(1.week.ago, PayoutProcessorType::PAYPAL, seller)
      expect(payout.user.payments.completed.where("created_at < ?", payout.created_at)).to be_empty

      sums = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]
        sums << payload[:sql] if payload[:sql].to_s.include?("SUM(")
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        Exports::Payouts::Csv.new(payment: payout).perform
      end

      expect(sums.size).to be < 100,
                           "Expected the export to stop aggregating per calendar day, got #{sums.size} SUM queries"
    end
  end

  def csv_safe(value)
    return value if value.nil?
    str = value.to_s
    return value if str.empty?
    first = str[0]
    if first == "+" || first == "-"
      return value if str[1..]&.match?(/\A\d+\.?\d*\z/)
    end
    %w[= @ | % \r \t + -].include?(first) ? "'#{value}" : value
  end

  def affiliate_net(parsed_csv)
    parsed_csv.select { |row| row.first == "Affiliate Credit" }.sum { |row| row.last.to_f }
  end

  def affiliate_ledger_cents(payout)
    balance_transactions = BalanceTransaction.where(balance_id: payout.balances.ids)
    AffiliateCredit.where(affiliate_credit_success_balance_id: payout.balances.ids).sum(:amount_cents) +
      balance_transactions.where.not(dispute_id: nil).sum(:issued_amount_gross_cents) +
      balance_transactions.joins(:refund).merge(Refund.effective).sum(:issued_amount_gross_cents)
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
