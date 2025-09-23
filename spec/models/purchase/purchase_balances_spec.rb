# frozen_string_literal: true

require "spec_helper"

describe "PurchaseBalances", :vcr  do
  include CurrencyHelper
  include ProductsHelper

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  describe "proper Balance creation and association with purchases" do
    let(:physical) { false }
    let(:admin_user) { create(:admin_user) }

    before do
      @user = create(:user)
      @product = create(:product, user: @user, is_physical: physical, require_shipping: physical, shipping_destinations: [(create(:shipping_destination) if physical)].compact)
      @old_date = Date.today - 10
      travel_to(@old_date) do
        # purchase_1 = prior to having a merchant account
        @purchase_1 = create(:purchase, chargeable: build(:chargeable), seller: @user, link: @product, purchase_state: "in_progress", price_cents: 100, fee_cents: 30,
                                        full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA", city: "San Francisco", zip_code: "94017", country: "United States")
        @purchase_1.process!
        @purchase_1.update_balance_and_mark_successful!

        # purchase_2 = with a merchant account
        @merchant_account = create(:merchant_account_stripe, user: @user)
        @user.reload
        @product.price_cents = 200
        @product.save
        @purchase_2 = create(:purchase, chargeable: build(:chargeable), seller: @user, link: @product, purchase_state: "in_progress", price_cents: 200, fee_cents: 35,
                                        full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA", city: "San Francisco", zip_code: "94017", country: "United States")
        @purchase_2.process!
        @purchase_2.update_balance_and_mark_successful!
      end
      @gumroad_merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    end

    describe "digital" do
      let(:physical) { false }

      it "associates the balance with the purchase and have the proper amount" do
        balance_1, balance_2 = Balance.last(2)

        expect(balance_1).to eq @purchase_1.purchase_success_balance
        expect(balance_1.date).to eq @old_date
        expect(balance_1.amount_cents).to eq 7 # 100c price - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)
        expect(balance_1.merchant_account).to eq(@gumroad_merchant_account)

        expect(balance_2).to eq @purchase_2.purchase_success_balance
        expect(balance_2.date).to eq @old_date
        expect(balance_2.amount_cents).to eq 94 # 200c price - 20c (10% flat fee) - 50c (fixed fee) - 6c (2.9% cc fee) - 30c (fixed cc fee)
        expect(balance_2.merchant_account).to eq(@merchant_account)

        expect(@user.unpaid_balance_cents).to eq 101
      end

      it "uses the same balance for refund/chargeback as the one used for the original purchase (if unpaid)" do
        purchase_balance_1 = @purchase_1.purchase_success_balance

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_1.refund_and_save!(admin_user.id)
        end

        refund_balance_1 = @purchase_1.reload.purchase_refund_balance
        expect(refund_balance_1).to eq purchase_balance_1

        purchase_balance_2 = @purchase_2.purchase_success_balance
        @purchase_2.refund_and_save!(admin_user.id)
        refund_balance_2 = @purchase_2.reload.purchase_refund_balance
        expect(refund_balance_2).to eq purchase_balance_2
      end

      it "uses the oldest unpaid balance for refund/chargeback if the original purchase balance is not unpaid" do
        purchase_balance_1 = @purchase_1.purchase_success_balance
        purchase_balance_1.update_attribute(:state, "paid")
        old_unpaid_balance_1 = create(:balance, user: @user, merchant_account: @purchase_1.merchant_account, date: Date.today - 9)
        create(:balance, user: @user, merchant_account: @purchase_1.merchant_account, date: Date.today)

        purchase_balance_2 = @purchase_2.purchase_success_balance
        purchase_balance_2.update_attribute(:state, "paid")
        old_unpaid_balance_2 = create(:balance, user: @user, merchant_account: @purchase_2.merchant_account, date: Date.today - 9)
        create(:balance, user: @user, merchant_account: @purchase_2.merchant_account, date: Date.today)

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_1.refund_and_save!(admin_user.id)
        end

        refund_balance_1 = @purchase_1.reload.purchase_refund_balance
        expect(refund_balance_1).to eq old_unpaid_balance_1

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_2.refund_and_save!(admin_user.id)
        end

        refund_balance_2 = @purchase_2.reload.purchase_refund_balance
        expect(refund_balance_2).to eq old_unpaid_balance_2
      end

      it "uses today's balance for refund/chargeback if the original purchase balance is not unpaid and there are no older unpaid balances" do
        purchase_balance_1 = @purchase_1.purchase_success_balance
        purchase_balance_1.mark_processing!
        purchase_balance_1.mark_paid!
        old_paid_balance_1 = create(:balance, user: @user, merchant_account: @purchase_1.merchant_account, date: Date.today - 9)
        old_paid_balance_1.mark_processing!
        old_paid_balance_1.mark_paid!
        today_unpaid_balance_1 = create(:balance, user: @user, merchant_account: @purchase_1.merchant_account, date: Date.today)

        purchase_balance_2 = @purchase_2.purchase_success_balance
        purchase_balance_2.mark_processing!
        purchase_balance_2.mark_paid!
        old_paid_balance_2 = create(:balance, user: @user, merchant_account: @purchase_2.merchant_account, date: Date.today - 9)
        old_paid_balance_2.mark_processing!
        old_paid_balance_2.mark_paid!
        today_unpaid_balance_2 = create(:balance, user: @user, merchant_account: @purchase_2.merchant_account, date: Date.today)

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_1.refund_and_save!(admin_user.id)
        end

        refund_balance_1 = @purchase_1.reload.purchase_refund_balance
        expect(refund_balance_1).to eq today_unpaid_balance_1

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_2.refund_and_save!(admin_user.id)
        end

        refund_balance_2 = @purchase_2.reload.purchase_refund_balance
        expect(refund_balance_2).to eq today_unpaid_balance_2
      end
    end

    describe "physical" do
      let(:physical) { true }

      it "associates the balance with the purchase and have the proper amount" do
        balance_1, balance_2 = Balance.last(2)

        expect(balance_1).to eq @purchase_1.purchase_success_balance
        expect(balance_1.date).to eq @old_date
        expect(balance_1.amount_cents).to eq 7
        expect(balance_1.merchant_account).to eq(@gumroad_merchant_account)

        expect(balance_2).to eq @purchase_2.purchase_success_balance
        expect(balance_2.date).to eq @old_date
        expect(balance_2.amount_cents).to eq 94
        expect(balance_2.merchant_account).to eq(@merchant_account)

        expect(@user.unpaid_balance_cents).to eq 101
      end

      it "uses the same balance for refund/chargeback as the one used for the original purchase (if unpaid)" do
        purchase_balance_1 = @purchase_1.purchase_success_balance
        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_1.refund_and_save!(admin_user.id)
        end
        refund_balance_1 = @purchase_1.reload.purchase_refund_balance
        expect(refund_balance_1).to eq purchase_balance_1

        purchase_balance_2 = @purchase_2.purchase_success_balance
        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_2.refund_and_save!(admin_user.id)
        end
        refund_balance_2 = @purchase_2.reload.purchase_refund_balance
        expect(refund_balance_2).to eq purchase_balance_2
      end

      it "uses the oldest unpaid balance for refund/chargeback if the original purchase balance is not unpaid" do
        purchase_balance_1 = @purchase_1.purchase_success_balance
        purchase_balance_1.update_attribute(:state, "paid")
        old_unpaid_balance_1 = create(:balance, user: @user, merchant_account: @purchase_1.merchant_account, date: Date.today - 9)
        create(:balance, user: @user, merchant_account: @purchase_1.merchant_account, date: Date.today)

        purchase_balance_2 = @purchase_2.purchase_success_balance
        purchase_balance_2.update_attribute(:state, "paid")
        old_unpaid_balance_2 = create(:balance, user: @user, merchant_account: @purchase_2.merchant_account, date: Date.today - 9)
        create(:balance, user: @user, merchant_account: @purchase_2.merchant_account, date: Date.today)

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_1.refund_and_save!(admin_user.id)
        end
        refund_balance_1 = @purchase_1.reload.purchase_refund_balance
        expect(refund_balance_1).to eq old_unpaid_balance_1

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_2.refund_and_save!(admin_user.id)
        end
        refund_balance_2 = @purchase_2.reload.purchase_refund_balance
        expect(refund_balance_2).to eq old_unpaid_balance_2
      end

      it "uses today's balance for refund/chargeback if the original purchase balance is not unpaid and there are no older unpaid balances" do
        purchase_balance_1 = @purchase_1.purchase_success_balance
        purchase_balance_1.mark_processing!
        purchase_balance_1.mark_paid!
        old_paid_balance_1 = create(:balance, user: @user, merchant_account: @purchase_1.merchant_account, date: Date.today - 9)
        old_paid_balance_1.mark_processing!
        old_paid_balance_1.mark_paid!
        today_unpaid_balance_1 = create(:balance, user: @user, merchant_account: @purchase_1.merchant_account, date: Date.today)

        purchase_balance_2 = @purchase_2.purchase_success_balance
        purchase_balance_2.mark_processing!
        purchase_balance_2.mark_paid!
        old_paid_balance_2 = create(:balance, user: @user, merchant_account: @purchase_2.merchant_account, date: Date.today - 9)
        old_paid_balance_2.mark_processing!
        old_paid_balance_2.mark_paid!
        today_unpaid_balance_2 = create(:balance, user: @user, merchant_account: @purchase_2.merchant_account, date: Date.today)

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_1.refund_and_save!(admin_user.id)
        end
        refund_balance_1 = @purchase_1.reload.purchase_refund_balance
        expect(refund_balance_1).to eq today_unpaid_balance_1

        travel_to(Time.zone.local(2023, 11, 27)) do
          @purchase_2.refund_and_save!(admin_user.id)
        end
        refund_balance_2 = @purchase_2.reload.purchase_refund_balance
        expect(refund_balance_2).to eq today_unpaid_balance_2
      end
    end
  end

  describe "proper Balance creation and association with affiliate_credit" do
    let(:physical) { false }
    let(:user) { create(:user) }
    let(:product) do
      create(:product, user:, is_physical: physical, require_shipping: physical,
                       shipping_destinations: [(create(:shipping_destination) if physical)].compact)
    end
    let(:affiliate_user) { create(:affiliate_user) }
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: user) }
    let!(:product_affiliate) { create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 15_00) }
    let(:chargeable) { build(:chargeable) }
    let(:old_date) { Date.today - 10 }

    it "associates the balance with the purchase and affiliate_credit and have the proper amount for both" do
      travel_to(old_date) do
        @purchase_1 = create(:purchase, chargeable:, purchase_state: "in_progress", seller: user, link: product, price_cents: 100, fee_cents: 30,
                                        full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA", city: "San Francisco", zip_code: "94017", country: "United States",
                                        affiliate: direct_affiliate)
        @purchase_1.process!
        @purchase_1.update_balance_and_mark_successful!
      end

      affiliate_balance, seller_balance = Balance.last(2)

      expect(seller_balance).to eq @purchase_1.purchase_success_balance
      expect(@purchase_1.affiliate_credit).to_not be(nil)
      expect(seller_balance.date).to eq old_date
      expect(seller_balance.amount_cents).to eq(6) # 100c (price) - 15c (affiliate fee) + 14c (affiliate's share of Gumroad fee) - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)

      expect(affiliate_balance.date).to eq old_date
      expect(affiliate_balance.amount_cents).to eq 1

      verify_balance(user, 6)
      verify_balance(affiliate_user.reload, 1)
    end

    describe "when the app owner and creator get their own merchant accounts" do
      let(:product_2) do
        create(:product, user:, is_physical: physical, require_shipping: physical, price_cents: 200,
                         shipping_destinations: [(create(:shipping_destination) if physical)].compact)
      end
      let!(:product_affiliate_2) { create(:product_affiliate, product: product_2, affiliate: direct_affiliate, affiliate_basis_points: 20_00) }

      before do
        travel_to(old_date) do
          @purchase_1 = create(:purchase, chargeable:, purchase_state: "in_progress", seller: user, link: product, price_cents: 100, fee_cents: 30,
                                          full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA", city: "San Francisco", zip_code: "94017", country: "United States",
                                          affiliate: direct_affiliate)
          @purchase_1.process!
          @purchase_1.update_balance_and_mark_successful!
        end

        @merchant_account = create(:merchant_account, user:)
        @gumroad_merchant_account = MerchantAccount.gumroad(@merchant_account.charge_processor_id)
        user.reload

        travel_to(old_date) do
          @purchase_2 = create(:purchase, chargeable: build(:chargeable), purchase_state: "in_progress", seller: user, link: product_2, price_cents: 200, fee_cents: 35,
                                          full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA", city: "San Francisco", zip_code: "94017", country: "United States",
                                          affiliate: direct_affiliate)
          @purchase_2.process!
          @purchase_2.update_balance_and_mark_successful!
        end
      end

      describe "digital" do
        let(:physical) { false }

        it "associates the balance with the purchase and affiliate_credit and have the proper amount for both" do
          affiliate_balance, seller_balance_1, seller_balance_2 = Balance.last(3)
          # seller_balance_1 = balance for purchases prior to having their own merchant account
          # seller_balance_2 = should be nil

          expect(seller_balance_1).to eq @purchase_1.purchase_success_balance
          expect(@purchase_1.affiliate_credit).to_not be(nil)
          expect(seller_balance_1.date).to eq old_date
          expect(seller_balance_1.amount_cents).to eq(6) # 100c (price) - 15c (affiliate fee) + 14c (affiliate's share of Gumroad fee) - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)
          expect(seller_balance_1.merchant_account).to eq(@gumroad_merchant_account)

          expect(seller_balance_2).to eq @purchase_2.purchase_success_balance
          expect(@purchase_2.affiliate_credit).to_not be(nil)
          expect(seller_balance_2.date).to eq old_date
          expect(seller_balance_2.amount_cents).to eq 76 # 200c (price) - 40c (affiliate fee) + 22c (affiliate's share of Gumroad fee) - 20c (10% flat fee) - 50c (fixed fee) - 6c (2.9% cc fee) - 30c (fixed cc fee)
          expect(seller_balance_2.merchant_account).to eq(@merchant_account)

          expect(affiliate_balance.date).to eq old_date
          expect(affiliate_balance.amount_cents).to eq 19
          expect(affiliate_balance.merchant_account).to eq(@gumroad_merchant_account)

          verify_balance(user, 82)
          verify_balance(affiliate_user.reload, 19)
        end
      end

      describe "physical" do
        let(:physical) { true }

        it "associates the balance with the purchase and affiliate_credit and have the proper amount for both" do
          affiliate_balance, seller_balance_1, seller_balance_2 = Balance.last(3)
          # seller_balance_1 = balance for purchases prior to having their own merchant account
          # seller_balance_2 = balance for purchases on their own merchant account

          expect(seller_balance_1).to eq @purchase_1.purchase_success_balance
          expect(@purchase_1.affiliate_credit).to_not be(nil)
          expect(seller_balance_1.date).to eq old_date
          expect(seller_balance_1.amount_cents).to eq(6) # 100c (price) - 15c (affiliate fee) + 14c (affiliate's share of Gumroad fee) - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)
          expect(seller_balance_1.merchant_account).to eq(@gumroad_merchant_account)

          expect(seller_balance_2).to eq @purchase_2.purchase_success_balance
          expect(@purchase_2.affiliate_credit).to_not be(nil)
          expect(seller_balance_2.date).to eq old_date
          expect(seller_balance_2.amount_cents).to eq 76 # 200c (price) - 40c (affiliate fee) + 22c (affiliate's share of gumroad fee) - 20c (10% flat fee) - 50c (fixed fee) - 6c (2.9% cc fee) - 30c (fixed cc fee)
          expect(seller_balance_2.merchant_account).to eq(@merchant_account)

          expect(affiliate_balance.date).to eq old_date
          expect(affiliate_balance.amount_cents).to eq 19
          expect(affiliate_balance.merchant_account).to eq(@gumroad_merchant_account)

          verify_balance(user, 82)
          verify_balance(affiliate_user.reload, 19)
        end
      end
    end
  end

  describe "proper Balance creation and association with affiliate_credit with merchant_migration enabled" do
    let(:physical) { false }
    let(:user) { create(:user) }
    let(:product) do
      create(:product, user:, is_physical: physical, require_shipping: physical,
                       shipping_destinations: [(create(:shipping_destination) if physical)].compact)
    end
    let(:affiliate_user) { create(:affiliate_user) }
    let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller: user) }
    let!(:product_affiliate) { create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 15_00) }
    let(:chargeable) { build(:chargeable) }
    let(:old_date) { Date.today - 10 }

    before do
      Feature.activate_user(:merchant_migration, user)
      create(:user_compliance_info, user:)
    end

    after do
      Feature.deactivate_user(:merchant_migration, user)
    end

    it "associates the balance with the purchase and affiliate_credit and have the proper amount for both" do
      travel_to(old_date) do
        @purchase_1 = create(:purchase, chargeable:, purchase_state: "in_progress", seller: user, link: product, price_cents: 100, fee_cents: 30,
                                        full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA", city: "San Francisco", zip_code: "94017", country: "United States",
                                        affiliate: direct_affiliate)
        @purchase_1.process!
        @purchase_1.update_balance_and_mark_successful!
      end

      affiliate_balance, seller_balance = Balance.last(2)

      expect(seller_balance).to eq @purchase_1.purchase_success_balance
      expect(@purchase_1.affiliate_credit).to_not be(nil)
      expect(seller_balance.date).to eq old_date
      expect(seller_balance.amount_cents).to eq(6) # 100c (price) - 15c (affiliate fee) + 14c (affiliate's share of gumroad fee) - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)

      expect(affiliate_balance.date).to eq old_date
      expect(affiliate_balance.amount_cents).to eq 1

      verify_balance(user, 6)
      verify_balance(affiliate_user.reload, 1)
    end

    describe "when the app owner and creator get their own merchant accounts" do
      let(:product_2) do
        create(:product, user:, is_physical: physical, require_shipping: physical, price_cents: 200,
                         shipping_destinations: [(create(:shipping_destination) if physical)].compact)
      end
      let!(:product_affiliate_2) { create(:product_affiliate, product: product_2, affiliate: direct_affiliate, affiliate_basis_points: 20_00) }

      before do
        travel_to(old_date) do
          @purchase_1 = create(:purchase, chargeable:, purchase_state: "in_progress", seller: user, link: product, price_cents: 100, fee_cents: 30,
                                          full_name: "Edgar Gumstein", street_address: "123 Gum Road", state: "CA", city: "San Francisco", zip_code: "94017", country: "United States",
                                          affiliate: direct_affiliate)
          @purchase_1.process!
          @purchase_1.update_balance_and_mark_successful!
        end

        @merchant_account = create(:merchant_account_stripe_connect, user:)
        @gumroad_merchant_account = MerchantAccount.gumroad(@merchant_account.charge_processor_id)
        user.reload

        travel_to(old_date) do
          @purchase_2 = create(:purchase, chargeable: build(:chargeable, product_permalink: product_2.unique_permalink),
                                          purchase_state: "in_progress", seller: user, link: product_2, price_cents: 200,
                                          fee_cents: 35, full_name: "Edgar Gumstein", street_address: "123 Gum Road",
                                          state: "CA", city: "San Francisco", zip_code: "94017", country: "United States",
                                          affiliate: direct_affiliate)
          @purchase_2.process!
          @purchase_2.update_balance_and_mark_successful!
        end
      end

      describe "digital" do
        let(:physical) { false }

        it "associates the balance with the purchase and affiliate_credit and have the proper amount for both" do
          affiliate_balance, seller_balance_1 = Balance.last(2)

          expect(seller_balance_1).to eq @purchase_1.purchase_success_balance
          expect(@purchase_1.affiliate_credit).to_not be(nil)
          expect(@purchase_2.affiliate_credit).to_not be(nil)
          expect(seller_balance_1.date).to eq old_date
          expect(seller_balance_1.amount_cents).to eq(6) # 100c (price) - 15c (affiliate fee) + 14c (affiliate's share of gumroad fee) - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)
          expect(seller_balance_1.merchant_account).to eq(@gumroad_merchant_account)

          expect(affiliate_balance.date).to eq old_date
          expect(affiliate_balance.amount_cents).to eq 27
          expect(affiliate_balance.merchant_account).to eq(@gumroad_merchant_account)

          verify_balance(user, 6)
          verify_balance(affiliate_user.reload, 27)
        end
      end

      describe "physical" do
        let(:physical) { true }

        it "associates the balance with the purchase and affiliate_credit and have the proper amount for both" do
          affiliate_balance, seller_balance_1 = Balance.last(2)

          expect(seller_balance_1).to eq @purchase_1.purchase_success_balance
          expect(@purchase_1.affiliate_credit).to_not be(nil)
          expect(@purchase_2.affiliate_credit).to_not be(nil)
          expect(seller_balance_1.date).to eq old_date
          expect(seller_balance_1.amount_cents).to eq(6) # 100c (price) - 15c (affiliate fee) + 14c (affiliate's share of gumroad fee) - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)
          expect(seller_balance_1.merchant_account).to eq(@gumroad_merchant_account)

          expect(affiliate_balance.date).to eq old_date
          expect(affiliate_balance.amount_cents).to eq 27
          expect(affiliate_balance.merchant_account).to eq(@gumroad_merchant_account)

          verify_balance(user, 6)
          verify_balance(affiliate_user.reload, 27)
        end
      end
    end
  end

  describe "increment_sellers_balance!" do
    it "adds a balance to the user" do
      user = create(:user)
      link = create(:product, user:)
      expect(user.unpaid_balance_cents).to eq 0
      purchase = create(:purchase, price_cents: 1_00, fee_cents: 30, link:, seller: link.user)
      purchase.increment_sellers_balance!
      verify_balance(user, 7) # 100c (price) - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)
    end

    describe "increment_sellers_balance! without affiliate_credit without merchant account" do
      before do
        @seller = create(:user)
        @product = create(:product, user: @seller)

        @charge = nil
        original_charge_processor_charge = ChargeProcessor.method(:create_payment_intent_or_charge!)
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
          charge_intent = original_charge_processor_charge.call(*args, **kwargs)
          @charge = charge_intent.charge
          charge_intent
        end

        @purchase = create(:purchase_in_progress, seller: @seller, link: @product, affiliate: @direct_affiliate, chargeable: create(:chargeable))
        @purchase.process!

        @flow_of_funds = @charge.flow_of_funds
      end

      it "creates a balance transaction" do
        @purchase.increment_sellers_balance!
        balance_transaction = BalanceTransaction.last

        expect(balance_transaction.user).to eq(@seller)
        expect(balance_transaction.merchant_account).to eq(@purchase.merchant_account)
        expect(balance_transaction.refund).to eq(@purchase.refunds.last)
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_currency).to eq(@flow_of_funds.issued_amount.currency)
        expect(balance_transaction.issued_amount_gross_cents).to eq(@purchase.total_transaction_cents)
        expect(balance_transaction.issued_amount_gross_cents).to eq(@flow_of_funds.issued_amount.cents)
        expect(balance_transaction.issued_amount_net_cents).to eq(@purchase.payment_cents)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.holding_amount_currency).to eq(@flow_of_funds.gumroad_amount.currency)
        expect(balance_transaction.holding_amount_gross_cents).to eq(@purchase.total_transaction_cents)
        expect(balance_transaction.holding_amount_gross_cents).to eq(@flow_of_funds.gumroad_amount.cents)
        expect(balance_transaction.holding_amount_net_cents).to eq(@purchase.payment_cents)
      end
    end

    describe "increment_sellers_balance! without affiliate_credit with merchant account" do
      before do
        @seller = create(:user)
        @merchant_account = create(:merchant_account_stripe_canada, user: @seller)
        @product = create(:product, user: @seller)

        @charge = nil
        original_charge_processor_charge = ChargeProcessor.method(:create_payment_intent_or_charge!)
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
          charge_intent = original_charge_processor_charge.call(*args, **kwargs)
          @charge = charge_intent.charge
          charge_intent
        end

        @purchase = create(:purchase_in_progress, seller: @seller, link: @product, affiliate: @direct_affiliate, chargeable: create(:chargeable))
        @purchase.process!

        @flow_of_funds = @charge.flow_of_funds
      end

      it "creates one balance transaction for the purchase" do
        @purchase.increment_sellers_balance!
        balance_transaction = BalanceTransaction.last

        expect(balance_transaction.user).to eq(@seller)
        expect(balance_transaction.merchant_account).to eq(@purchase.merchant_account)
        expect(balance_transaction.refund).to eq(@purchase.refunds.last)
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_currency).to eq(@flow_of_funds.issued_amount.currency)
        expect(balance_transaction.issued_amount_gross_cents).to eq(@purchase.total_transaction_cents)
        expect(balance_transaction.issued_amount_gross_cents).to eq(@flow_of_funds.issued_amount.cents)
        expect(balance_transaction.issued_amount_net_cents).to eq(@purchase.payment_cents)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction.holding_amount_currency).to eq(@flow_of_funds.merchant_account_gross_amount.currency)
        expect(balance_transaction.holding_amount_currency).to eq(@flow_of_funds.merchant_account_net_amount.currency)
        expect(balance_transaction.holding_amount_gross_cents).to eq(@flow_of_funds.merchant_account_gross_amount.cents)
        expect(balance_transaction.holding_amount_net_cents).to eq(@flow_of_funds.merchant_account_net_amount.cents)
      end
    end

    describe "increment_sellers_balance! with affiliate_credit with merchant account" do
      before do
        @seller = create(:user)
        Feature.deactivate_user(:merchant_migration, @seller)
        @merchant_account = create(:merchant_account_stripe_canada, user: @seller)
        @product = create(:product, user: @seller, price_cents: 10_00)
        @affiliate_user = create(:affiliate_user)
        @direct_affiliate = create(:direct_affiliate, affiliate_user: @affiliate_user, seller: @seller, products: [@product])

        @charge = nil
        original_charge_processor_charge = ChargeProcessor.method(:create_payment_intent_or_charge!)
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
          charge_intent = original_charge_processor_charge.call(*args, **kwargs)
          @charge = charge_intent.charge
          charge_intent
        end

        @purchase = create(:purchase_in_progress, seller: @seller, link: @product, affiliate: @direct_affiliate, chargeable: create(:chargeable))
        @purchase.process!

        @flow_of_funds = @charge.flow_of_funds
      end

      it "creates an instance of affiliate_credit" do
        expect { @purchase.increment_sellers_balance! }.to change { AffiliateCredit.count }.by(1)
      end

      it "increases each affiliate application owners and sellers balances accordingly" do
        @purchase.increment_sellers_balance!
        affiliate_user_balance = ((@purchase.price_cents - @purchase.fee_cents) * (@direct_affiliate.affiliate_basis_points / 10_000.0)).floor
        verify_balance(@affiliate_user, affiliate_user_balance)
        verify_balance(@seller, @purchase.price_cents - @purchase.fee_cents - affiliate_user_balance)
      end

      it "creates two balance transactions for the purchase" do
        @purchase.increment_sellers_balance!
        balance_transaction_1, balance_transaction_2 = BalanceTransaction.last(2)

        expect(balance_transaction_1.user).to eq(@affiliate_user)
        expect(balance_transaction_1.merchant_account).to eq(@purchase.affiliate_merchant_account)
        expect(balance_transaction_1.refund).to eq(@purchase.refunds.last)
        expect(balance_transaction_1.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction_1.issued_amount_gross_cents).to eq(@purchase.affiliate_credit_cents)
        expect(balance_transaction_1.issued_amount_net_cents).to eq(@purchase.affiliate_credit_cents)
        expect(balance_transaction_1.holding_amount_currency).to eq(Currency::USD)
        expect(balance_transaction_1.holding_amount_gross_cents).to eq(@purchase.affiliate_credit_cents)
        expect(balance_transaction_1.holding_amount_net_cents).to eq(@purchase.affiliate_credit_cents)

        expect(balance_transaction_2.user).to eq(@seller)
        expect(balance_transaction_2.merchant_account).to eq(@purchase.merchant_account)
        expect(balance_transaction_2.refund).to eq(@purchase.refunds.last)
        expect(balance_transaction_2.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction_2.issued_amount_currency).to eq(@flow_of_funds.issued_amount.currency)
        expect(balance_transaction_2.issued_amount_gross_cents).to eq(@purchase.total_transaction_cents)
        expect(balance_transaction_2.issued_amount_gross_cents).to eq(@flow_of_funds.issued_amount.cents)
        expect(balance_transaction_2.issued_amount_net_cents).to eq((@purchase.payment_cents - @purchase.affiliate_credit_cents))
        expect(balance_transaction_2.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction_2.holding_amount_currency).to eq(@flow_of_funds.merchant_account_gross_amount.currency)
        expect(balance_transaction_2.holding_amount_currency).to eq(@flow_of_funds.merchant_account_net_amount.currency)
        expect(balance_transaction_2.holding_amount_gross_cents).to eq(@flow_of_funds.merchant_account_gross_amount.cents)
        expect(balance_transaction_2.holding_amount_net_cents).to eq(@flow_of_funds.merchant_account_net_amount.cents)
      end
    end
  end

  describe "increment_sellers_balance! with merchant_migration_enabled" do
    it "adds a balance to the user" do
      user = create(:user)
      Feature.activate_user(:merchant_migration, user)
      create(:user_compliance_info, user:)
      link = create(:product, user:)
      expect(user.unpaid_balance_cents).to eq 0
      purchase = create(:purchase, price_cents: 1_00, fee_cents: 30, link:, seller: link.user)
      purchase.increment_sellers_balance!
      verify_balance(user, 7) # 100c (price) - 10c (10% flat fee) - 50c (fixed fee) - 3c (2.9% cc fee) - 30c (fixed cc fee)
      Feature.deactivate_user(:merchant_migration, user)
    end

    describe "increment_sellers_balance! without affiliate_credit without merchant account" do
      before do
        @seller = create(:user)
        Feature.activate_user(:merchant_migration, @seller)
        create(:user_compliance_info, user: @seller)
        @product = create(:product, user: @seller)

        @charge = nil
        original_charge_processor_charge = ChargeProcessor.method(:create_payment_intent_or_charge!)
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
          charge_intent = original_charge_processor_charge.call(*args, **kwargs)
          @charge = charge_intent.charge
          charge_intent
        end

        @purchase = create(:purchase_in_progress, seller: @seller, link: @product, affiliate: @direct_affiliate, chargeable: create(:chargeable))
        @purchase.process!

        @flow_of_funds = @charge.flow_of_funds
      end

      after do
        Feature.deactivate_user(:merchant_migration, @seller)
      end

      it "creates a balance transaction" do
        @purchase.increment_sellers_balance!
        balance_transaction = BalanceTransaction.last

        expect(balance_transaction.user).to eq(@seller)
        expect(balance_transaction.merchant_account).to eq(@purchase.merchant_account)
        expect(balance_transaction.refund).to eq(@purchase.refunds.last)
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_currency).to eq(@flow_of_funds.issued_amount.currency)
        expect(balance_transaction.issued_amount_gross_cents).to eq(@purchase.total_transaction_cents)
        expect(balance_transaction.issued_amount_gross_cents).to eq(@flow_of_funds.issued_amount.cents)
        expect(balance_transaction.issued_amount_net_cents).to eq(@purchase.payment_cents)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.holding_amount_currency).to eq(@flow_of_funds.gumroad_amount.currency)
        expect(balance_transaction.holding_amount_gross_cents).to eq(@purchase.total_transaction_cents)
        expect(balance_transaction.holding_amount_gross_cents).to eq(@flow_of_funds.gumroad_amount.cents)
        expect(balance_transaction.holding_amount_net_cents).to eq(@purchase.payment_cents)
      end
    end

    describe "increment_sellers_balance! without affiliate_credit with merchant account" do
      before do
        @seller = create(:user)
        Feature.activate_user(:merchant_migration, @seller)
        create(:user_compliance_info, user: @seller)
        @merchant_account = create(:merchant_account_stripe_connect, user: @seller)
        @product = create(:product, user: @seller)

        @charge = nil
        original_charge_processor_charge = ChargeProcessor.method(:create_payment_intent_or_charge!)
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
          charge_intent = original_charge_processor_charge.call(*args, **kwargs)
          @charge = charge_intent.charge
          charge_intent
        end

        chargeable = create(:chargeable, product_permalink: @product.unique_permalink)
        @purchase = create(:purchase_in_progress, seller: @seller, link: @product, affiliate: @direct_affiliate, chargeable:)
        @purchase.process!

        @flow_of_funds = @charge.flow_of_funds
      end

      after do
        Feature.deactivate_user(:merchant_migration, @seller)
      end

      it "does not create balance transaction for the purchase" do
        @purchase.increment_sellers_balance!
        balance_transaction = BalanceTransaction.last

        expect(balance_transaction).to be(nil)
      end
    end

    describe "increment_sellers_balance! with affiliate_credit with merchant account" do
      before do
        @seller = create(:user)
        Feature.activate_user(:merchant_migration, @seller)
        create(:user_compliance_info, user: @seller)
        @merchant_account = create(:merchant_account_stripe_connect, user: @seller)
        @product = create(:product, user: @seller)
        @affiliate_user = create(:affiliate_user)
        @direct_affiliate = create(:direct_affiliate, affiliate_user: @affiliate_user, seller: @seller, products: [@product])

        chargeable = create(:chargeable, product_permalink: @product.unique_permalink)
        @purchase = create(:purchase_in_progress, seller: @seller, link: @product, affiliate: @direct_affiliate, chargeable:)
        @purchase.process!
      end

      after do
        Feature.deactivate_user(:merchant_migration, @seller)
      end

      it "creates an instance of affiliate_credit" do
        expect { @purchase.increment_sellers_balance! }.to change { AffiliateCredit.count }.by(1)
      end

      it "increases each affiliate application owners and sellers balances accordingly" do
        @purchase.increment_sellers_balance!
        affiliate_user_balance = ((@purchase.price_cents - @purchase.fee_cents) * (@direct_affiliate.affiliate_basis_points / 10_000.0)).floor
        verify_balance(@affiliate_user, affiliate_user_balance)
        verify_balance(@seller, 0)
      end

      it "creates only one balance transactions for the purchase" do
        expect { @purchase.increment_sellers_balance! }.to change(BalanceTransaction, :count).by(1)

        balance_transaction = BalanceTransaction.last

        expect(balance_transaction.user).to eq(@affiliate_user)
        expect(balance_transaction.merchant_account).to eq(@purchase.affiliate_merchant_account)
        expect(balance_transaction.refund).to eq(@purchase.refunds.last)
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_gross_cents).to eq(@purchase.affiliate_credit_cents)
        expect(balance_transaction.issued_amount_net_cents).to eq(@purchase.affiliate_credit_cents)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.holding_amount_gross_cents).to eq(@purchase.affiliate_credit_cents)
        expect(balance_transaction.holding_amount_net_cents).to eq(@purchase.affiliate_credit_cents)
      end
    end
  end
end
