# frozen_string_literal: true

require "spec_helper"

describe PayoutsHelper do
  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  describe "formatted_payout_date" do
    before do
      @user = create(:singaporean_user_with_compliance_info, payment_address: "balance@gumroad.com")
      WebMock.stub_request(:post, PAYPAL_ENDPOINT)
             .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Success&VERSION=90%2e0&BUILD=4072860")
    end

    it "returns the proper date for the current payout period given balance of 0" do
      payout_period_data = helper.payout_period_data(@user)
      expect(payout_period_data[:is_user_payable]).to be(false)
    end

    it "show proper date" do
      travel_to(Time.find_zone("UTC").local(2015, 3, 1)) do
        expect(formatted_payout_date(Date.current)).to eq("March 1st, 2015")
      end
    end

    it "returns the proper date for the current payout period given sales that span 2 payout periods" do
      @user = create(:singaporean_user_with_compliance_info, payment_address: "balance@gumroad.com")
      link = create(:product, user: @user, price_cents: 20_00)

      (0..13).each do |days_count|
        travel_to(Date.parse("2013-08-14") - days_count.days) do
          create(:purchase_with_balance, link:)
        end
      end

      travel_to(Date.parse("2013-08-14")) do
        payout_period_data = helper.payout_period_data(@user)
        expect(payout_period_data[:is_user_payable]).to be(true)
        expect(payout_period_data[:displayable_payout_period_range])
          .to eq "Activity up to #{formatted_payout_date(Date.parse("2013-08-09"))}"
        expect(payout_period_data[:payout_cents]).to eq 149_58
        expect(payout_period_data[:payout_date_formatted]).to eq formatted_payout_date(@user.next_payout_date)
        expect(payout_period_data[:paypal_address]).to eq @user.payment_address
        expect(payout_period_data[:arrival_date]).to be nil
      end
    end

    it "returns the proper sales amount for the current payout period given sales that span 2 payout periods" do
      @user = create(:singaporean_user_with_compliance_info, payment_address: "balance@gumroad.com")
      link = create(:product, user: @user, price_cents: 20_00)


      (0..1).each do |days_count|
        travel_to(Date.parse("2013-09-7") - days_count.days) do
          create(:purchase_with_balance, link:)
        end
      end

      travel_to(Date.parse("2013-09-7")) do
        payout_period_data = helper.payout_period_data(@user)
        expect(payout_period_data[:is_user_payable]).to be(true)
        expect(payout_period_data[:displayable_payout_period_range])
          .to eq "Activity up to #{formatted_payout_date(Date.parse("2013-09-06"))}"
        expect(payout_period_data[:payout_cents]).to eq 1662
        expect(payout_period_data[:payout_displayed_amount]).to eq("$16.62")
        expect(payout_period_data[:sales_cents]).to eq 2000
        expect(payout_period_data[:payout_date_formatted]).to eq formatted_payout_date(@user.next_payout_date)
        expect(payout_period_data[:paypal_address]).to eq @user.payment_address
      end
    end

    it "returns the proper data for the current payout period given sales that span 2 payout periods and one old payment" do
      @user = create(:singaporean_user_with_compliance_info, user_risk_state: "compliant", payment_address: "balance@gumroad.com")
      link = create(:product, user: @user, price_cents: 20_00)

      # 8/16 is a payout friday
      (0..13).each do |days_count|
        travel_to(Date.parse("2013-08-20") - days_count.days) do
          create(:purchase_with_balance, link:)
        end
      end
      travel_to(Date.parse("2013-08-16")) do
        Payouts.create_payments_for_balances_up_to_date_for_users(Date.parse("2013-08-09"), PayoutProcessorType::PAYPAL, [@user])
        payment = Payment.last
        payment.update!(processor_fee_cents: 10, txn_id: "test")
        payment.mark_completed!
      end

      travel_to(Date.parse("2013-08-20")) do
        payout_period_data = helper.payout_period_data(@user)
        expect(payout_period_data[:is_user_payable]).to be(true)
        expect(payout_period_data[:displayable_payout_period_range])
        expect(payout_period_data[:displayable_payout_period_range]).to eq "Activity from #{formatted_payout_date(Date.parse("2013-08-10"))} to #{formatted_payout_date(Date.parse("2013-08-16"))}"
        expect(payout_period_data[:payout_cents]).to eq 116_34
        expect(payout_period_data[:payout_date_formatted]).to eq formatted_payout_date(@user.next_payout_date)
        expect(payout_period_data[:paypal_address]).to eq @user.payment_address
      end
    end

    it "returns the proper date for the current payout period given sales that span 2 payout periods \
        given that today falls after the latest unpaid payout period" do
      @user = create(:singaporean_user_with_compliance_info, user_risk_state: "compliant", payment_address: "balance@gumroad.com")
      link = create(:product, user: @user, price_cents: 20_00)

      # 8/16 is a payout friday

      (0..20).each do |days_count|
        travel_to(Date.parse("2013-08-25") - days_count.days) do
          create(:purchase_with_balance, link:)
        end
      end
      travel_to(Date.parse("2013-08-16")) do
        Payouts.create_payments_for_balances_up_to_date_for_users(Date.parse("2013-08-09"), PayoutProcessorType::PAYPAL, [@user])
        payment = Payment.last
        payment.update!(processor_fee_cents: 10, txn_id: "test")
        payment.mark_completed!
      end

      travel_to(Date.parse("2013-08-25")) do
        payout_period_data = helper.payout_period_data(@user)
        expect(payout_period_data[:is_user_payable]).to be(true)
        expect(payout_period_data[:displayable_payout_period_range]) .to eq "Activity from #{formatted_payout_date(Date.parse("2013-08-10"))} to #{formatted_payout_date(Date.parse("2013-08-23"))}"
        expect(payout_period_data[:payout_cents]).to eq 232_68
        expect(payout_period_data[:payout_date_formatted]).to eq formatted_payout_date(@user.next_payout_date)
        expect(payout_period_data[:paypal_address]).to eq @user.payment_address
      end
    end

    it "returns the proper date for an old payment" do
      @user = create(:singaporean_user_with_compliance_info, payment_address: "balance@gumroad.com")
      link = create(:product, user: @user, price_cents: 20_00)

      # 8/16 is a payout friday
      (0..20).each do |days_count|
        travel_to(Date.parse("2013-08-25") - days_count.days) do
          create(:purchase_with_balance, link:)
        end
      end

      travel_to(Date.parse("2013-08-16")) do
        Payouts.create_payments_for_balances_up_to_date_for_users(Date.parse("2013-08-09"), PayoutProcessorType::PAYPAL, [@user])
        payment = Payment.last
        payment.update!(processor_fee_cents: 10, txn_id: "test")
        payment.mark_completed!
      end


      travel_to(Date.parse("2013-08-25")) do
        payment = Payment.last
        payout_period_data = helper.payout_period_data(@user, payment)
        expect(payout_period_data[:displayable_payout_period_range]).to eq "Activity up to #{formatted_payout_date(Date.parse("2013-08-09"))}"
        expect(payout_period_data[:payout_currency]).to eq Currency::USD
        expect(payout_period_data[:payout_cents]).to eq 8143
        expect(payout_period_data[:payout_displayed_amount]).to eq "$81.43"
        expect(payout_period_data[:payout_date_formatted]).to eq formatted_payout_date(payment.created_at)
        expect(payout_period_data[:paypal_address]).to eq @user.payment_address
      end
    end

    describe "displayable_payout_period_range" do
      let(:seller) { create(:compliant_user, unpaid_balance_cents: 10_01) }
      let!(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
      let(:stripe_connect_account_id) { merchant_account.charge_processor_merchant_id }

      before do
        create(:ach_account, user: seller, stripe_bank_account_id: stripe_connect_account_id)
        create(:user_compliance_info, user: seller)
      end

      it "renders the correct displayable_payout_period_range when 2 payouts have the same date" do
        travel_to(Date.parse("2024-11-22")) do
          instant_payout = create(:payment,
                                  user: seller,
                                  processor: PayoutProcessorType::STRIPE,
                                  state: "processing",
                                  stripe_connect_account_id:,
                                  json_data: {
                                    payout_type: Payouts::PAYOUT_TYPE_INSTANT,
                                    gumroad_fee_cents: 125
                                  })
          standard_payout = create(:payment,
                                   user: seller,
                                   processor: PayoutProcessorType::STRIPE,
                                   state: "processing",
                                   stripe_connect_account_id:)

          instant_payout_period_data = helper.payout_period_data(seller, instant_payout)
          expect(instant_payout_period_data[:displayable_payout_period_range]).to eq("Activity up to November 21st, 2024")
          expect(instant_payout_period_data[:fees_cents]).to eq(125)

          standard_payout_period_data = helper.payout_period_data(seller, standard_payout)
          expect(standard_payout_period_data[:displayable_payout_period_range]).to eq("Activity on November 21st, 2024")
        end
      end
    end
  end

  describe "refund for affiliate credits" do
    it "makes sure that balances are correct for seller and affiliate user when an affiliate credit \
        is paid out in one pay period and then refunded in the next", :vcr do
      @seller = create(:singaporean_user_with_compliance_info, payment_address: "sahil@gumroad.com")
      link = create(:product, user: @seller, price_cents: 20_000)
      @affiliate_user = create(:singaporean_user_with_compliance_info, payment_address: "balance@gumroad.com")
      @direct_affiliate = create(:direct_affiliate, affiliate_user: @affiliate_user, seller: @seller, affiliate_basis_points: 1500, products: [link])

      travel_to(1.week.ago) do
        @purchase = create(:purchase_in_progress, link:, affiliate: @direct_affiliate)
        @purchase.process!
        @purchase.update_balance_and_mark_successful!
      end

      Payouts.create_payments_for_balances_up_to_date_for_users(Date.current.yesterday, PayoutProcessorType::PAYPAL, User.holding_balance)

      @purchase_refund_flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase.total_transaction_cents)
      @purchase.refund_purchase!(@purchase_refund_flow_of_funds, @seller.id)
      @affiliate_user.reload
      @seller.reload
      verify_balance(@affiliate_user, @affiliate_user.affiliate_credits.last.affiliate_credit_refund_balance.amount_cents)
      expect(@affiliate_user.balances.count).to eq 2
      expect(@affiliate_user.balances.first.amount_cents).to eq @purchase.affiliate_credit_cents
      expect(@affiliate_user.balances.first.state).to eq "processing"
      expect(@affiliate_user.balances.last.amount_cents).to eq(-@purchase.affiliate_credit_cents)
      expect(@affiliate_user.balances.last.state).to eq "unpaid"
      fully_refunded_sale = @seller.sales.successful.where("purchases.price_cents > 0 AND purchases.stripe_refunded = 1").last
      verify_balance(@seller, fully_refunded_sale.purchase_refund_balance.amount_cents)
      expect(@seller.balances.count).to eq 2
      expect(@seller.balances.first.amount_cents).to eq Purchase.sum("price_cents - fee_cents - affiliate_credit_cents")
      expect(@seller.balances.first.state).to eq "processing"
      retained_fee_cents = (@purchase.price_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0).round + Purchase::PROCESSOR_FIXED_FEE_CENTS
      expect(@seller.balances.last.amount_cents).to eq(-@purchase.price_cents + @purchase.affiliate_credit_cents + @purchase.fee_cents - retained_fee_cents)
      expect(@seller.balances.last.state).to eq "unpaid"
    end
  end

  describe "payout period data" do
    it "shows minimum payout volume for user without enough balance" do
      user = create(:user)
      expect(self.payout_period_data(user)[:is_user_payable]).to eq(false)
      expect(self.payout_period_data(user)[:minimum_payout_amount_cents]).to eq(1000)
    end

    it "shows payout data without payout given and no previous payouts" do
      travel_to(Time.find_zone("UTC").local(2015, 3, 1)) do
        user = create(:user)
        create(:ach_account, user:)
        create(:balance, user:, amount_cents: 10_00, date: Date.current)
        create(:bank, routing_number: "110000000", name: "Bank of America")
        expect(self.payout_period_data(user)[:is_user_payable]).to eq(true)
        expect(self.payout_period_data(user)[:displayable_payout_period_range]).to eq("Activity up to now")
        expect(self.payout_period_data(user)[:payout_date_formatted]).to eq("March 13th, 2015")
        expect(self.payout_period_data(user)[:payout_cents]).to eq(1000)
        expect(self.payout_period_data(user)[:bank_number]).to eq("110000000")
        expect(self.payout_period_data(user)[:account_number]).to eq("******1234")
        expect(self.payout_period_data(user)[:bank_account_type]).to eq("ACH")
        expect(self.payout_period_data(user)[:bank_name]).to eq("Bank of America")
      end
    end

    it "shows payout data without payout given and previous payouts" do
      travel_to(Time.find_zone("UTC").local(2015, 3, 1)) do
        user = create(:user)
        create(:ach_account, user:)
        payment = create(:payment, user:, amount_cents: 10_00)
        balance = create(:balance, user:, amount_cents: 10_00, date: Date.current - 30.days, state: "paid")
        payment.balances << balance
        create(:balance, user:, amount_cents: 10_00, date: Date.current)
        create(:bank, routing_number: "110000000", name: "Bank of America")
        expect(self.payout_period_data(user)[:is_user_payable]).to eq(true)
        expect(self.payout_period_data(user)[:displayable_payout_period_range]).to eq("Activity since March 1st, 2015")
        expect(self.payout_period_data(user)[:payout_date_formatted]).to eq("March 13th, 2015")
        expect(self.payout_period_data(user)[:payout_cents]).to eq(1000)
        expect(self.payout_period_data(user)[:bank_number]).to eq("110000000")
        expect(self.payout_period_data(user)[:account_number]).to eq("******1234")
        expect(self.payout_period_data(user)[:bank_name]).to eq("Bank of America")
      end
    end

    it "shows user's payout data with payout given and previous payouts" do
      travel_to(Time.find_zone("UTC").local(2015, 3, 1)) do
        user = create(:user)
        payment = create(:payment, user:, amount_cents: 10_00, arrival_date: 1.week.ago.to_i)
        balance = create(:balance, user:, amount_cents: 10_00, date: 30.days.ago, state: "paid")
        payment.balances << balance
        bank_account = create(:ach_account)
        bank_account.payments << payment
        create(:balance, user:, amount_cents: 10_00, date: Date.current)
        create(:bank, routing_number: "110000000", name: "Bank of America")
        expect(self.payout_period_data(user, payment)[:is_user_payable]).to eq(nil)
        expect(self.payout_period_data(user, payment)[:displayable_payout_period_range]).to eq("Activity up to February 28th, 2015")
        expect(self.payout_period_data(user, payment)[:payout_date_formatted]).to eq("March 1st, 2015")
        expect(self.payout_period_data(user, payment)[:payout_currency]).to eq(Currency::USD)
        expect(self.payout_period_data(user, payment)[:payout_cents]).to eq(1000)
        expect(self.payout_period_data(user, payment)[:payout_displayed_amount]).to eq("$10")
        expect(self.payout_period_data(user, payment)[:bank_number]).to eq("110000000")
        expect(self.payout_period_data(user, payment)[:account_number]).to eq("******1234")
        expect(self.payout_period_data(user, payment)[:bank_account_type]).to eq("ACH")
        expect(self.payout_period_data(user, payment)[:bank_name]).to eq("Bank of America")
        expect(self.payout_period_data(user, payment)[:arrival_date]).to eq(1.week.ago.strftime("%B #{1.week.ago.day.ordinalize}, %Y"))
      end
    end

    it "shows user's affiliate credits and fees separately", :vcr do
      user, seller, affiliate_user = 3.times.map { create(:singaporean_user_with_compliance_info) }

      product = create(:product, user:, price_cents: 20_000)
      affiliate_product = create(:product, user: seller, price_cents: 50_000)

      affiliate_owed = create(:direct_affiliate, affiliate_user:, seller: user, affiliate_basis_points: 1500)
      affiliate_owed.products << product
      affiliate = create(:direct_affiliate, affiliate_user: user, seller:, affiliate_basis_points: 1000, products: [affiliate_product])

      product_purchase = create(:purchase_in_progress, link: product, affiliate: affiliate_owed)
      affiliate_purchase = create(:purchase_in_progress, link: affiliate_product, affiliate:)
      [product_purchase, affiliate_purchase].each do |purchase|
        purchase.process!
        purchase.update_balance_and_mark_successful!
      end

      travel_to(1.week.from_now) do
        Payouts.create_payments_for_balances_up_to_date_for_users(Date.current - 1, PayoutProcessorType::PAYPAL, User.holding_balance)

        period_data = self.payout_period_data(user, user.payments.last)
        expect(period_data[:affiliate_credits_cents]).to eq(43_47)
        expect(period_data[:affiliate_fees_cents]).to eq(26_01)
      end
    end

    it "includes the payout fee for instant payout under the fees head" do
      travel_to(Time.find_zone("UTC").local(2015, 3, 1)) do
        user = create(:user)
        payment = create(:payment,
                         user:,
                         amount_cents: 10_00,
                         arrival_date: 1.week.ago.to_i,
                         payout_type: Payouts::PAYOUT_TYPE_INSTANT,
                         gumroad_fee_cents: 30)
        balance = create(:balance, user:, amount_cents: 10_00, date: 30.days.ago, state: "paid")
        purchase = create(:purchase, link: create(:product, user:), purchase_success_balance_id: balance.id)
        payment.balances << balance
        bank_account = create(:ach_account)
        bank_account.payments << payment
        create(:bank, routing_number: "110000000", name: "Bank of America")

        payout_data = self.payout_period_data(user, payment)
        expect(payout_data[:is_user_payable]).to eq(nil)
        expect(payout_data[:displayable_payout_period_range]).to eq("Activity up to February 28th, 2015")
        expect(payout_data[:payout_date_formatted]).to eq("March 1st, 2015")
        expect(payout_data[:payout_currency]).to eq(Currency::USD)
        expect(payout_data[:payout_cents]).to eq(1000)
        expect(payout_data[:payout_displayed_amount]).to eq("$10")
        expect(payout_data[:bank_number]).to eq("110000000")
        expect(payout_data[:account_number]).to eq("******1234")
        expect(payout_data[:bank_account_type]).to eq("ACH")
        expect(payout_data[:bank_name]).to eq("Bank of America")
        expect(payout_data[:arrival_date]).to eq(1.week.ago.strftime("%B #{1.week.ago.day.ordinalize}, %Y"))
        expect(purchase.fee_cents).to eq(93)
        expect(payment.gumroad_fee_cents).to eq(30)
        expect(payout_data[:fees_cents]).to eq(123) # 93 cents fee on purchase + 30 cents on instant payout
      end
    end
  end
end
