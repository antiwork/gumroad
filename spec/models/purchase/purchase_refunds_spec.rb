# frozen_string_literal: true

require "spec_helper"

describe "PurchaseRefunds", :vcr do
  include CurrencyHelper
  include ProductsHelper

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  describe "refund purchase" do
    let(:merchant_account) { nil }

    before do
      @initial_balance = 200
      @user = create(:user)
      merchant_account
      @product = create(:product, user: @user)
      @purchase = create(:purchase_in_progress, link: @product, chargeable: create(:chargeable))
      @purchase.process!
      @purchase.mark_successful!
      @event = create(:event, event_name: "purchase", purchase_id: @purchase.id, link_id: @product.id)
      @balance = if merchant_account
        create(:balance, user: @user, amount_cents: @initial_balance, merchant_account:, holding_currency: Currency::CAD)
      else
        create(:balance, user: @user, amount_cents: @initial_balance)
      end
      @initial_num_paid_download = @product.sales.paid.count
    end

    it "only refunds with stripe id" do
      expect(ChargeProcessor).to_not receive(:refund!)
      @purchase.stripe_transaction_id = nil
      @purchase.refund_and_save!(@user.id)
    end

    it "updates refund status" do
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
      expect(@purchase.stripe_refunded).to_not be(true)
      @purchase.refund_and_save!(@user.id)
      @purchase.reload
      expect(@purchase.refunds.first.status).to eq("succeeded")
    end

    it "updates refund processor refund id" do
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
      expect(@purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original
      expect(@purchase.stripe_refunded).to_not be(true)

      @purchase.refund_and_save!(@user.id)

      expect(@purchase.reload.refunds.first.processor_refund_id).to_not be(nil)
    end

    it "refunds idempotent" do
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
      expect(@purchase.stripe_refunded).to_not be(true)
      @purchase.refund_and_save!(@user.id)
      @purchase.reload
      expect(@purchase.stripe_refunded).to_not be(false)
      @purchase.refund_and_save!(@user.id)
    end

    it "refunds when stripe_partially_refunded" do
      @purchase.stripe_partially_refunded = true
      @purchase.save!
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
      expect(@purchase.stripe_refunded).to_not be(true)
      @purchase.refund_and_save!(@user.id)
      @purchase.reload
      expect(@purchase.stripe_refunded).to_not be(false)
    end

    it "creates a balance transaction for the refund" do
      charge_refund = nil
      original_charge_processor_refund = ChargeProcessor.method(:refund!)
      expect(ChargeProcessor).to receive(:refund!) do |*args, **kwargs|
        charge_refund = original_charge_processor_refund.call(*args, **kwargs)
        charge_refund
      end

      @purchase.refund_and_save!(@user.id)
      flow_of_funds = charge_refund.flow_of_funds

      balance_transaction = BalanceTransaction.where.not(refund_id: nil).last
      expect(balance_transaction.user).to eq(@user)
      expect(balance_transaction.merchant_account).to eq(@purchase.merchant_account)
      expect(balance_transaction.refund).to eq(@purchase.refunds.last)
      expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
      expect(balance_transaction.issued_amount_currency).to eq(flow_of_funds.issued_amount.currency)
      expect(balance_transaction.issued_amount_gross_cents).to eq(-1 * @purchase.total_transaction_cents)
      expect(balance_transaction.issued_amount_gross_cents).to eq(flow_of_funds.issued_amount.cents)
      expect(balance_transaction.issued_amount_net_cents).to eq(-1 * @purchase.payment_cents)
      expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
      expect(balance_transaction.holding_amount_currency).to eq(flow_of_funds.gumroad_amount.currency)
      expect(balance_transaction.holding_amount_gross_cents).to eq(flow_of_funds.gumroad_amount.cents)
      expect(balance_transaction.holding_amount_net_cents).to eq(-1 * @purchase.payment_cents)
    end

    it "updates balance of seller and # paid downloads" do
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
      @purchase.refund_and_save!(@user.id)
      @user.reload
      verify_balance(@user, @initial_balance - @purchase.payment_cents - @purchase.processor_fee_cents)
      expect(@purchase.purchase_refund_balance).to eq @balance
      @product.reload
      expect(@product.sales.paid.count).to_not eq @initial_num_paid_download
      @product.sales.paid.count == @initial_num_paid_download - 1
    end

    describe "partial refund with amount" do
      it "updates refund status" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        expect(@purchase.stripe_refunded).to_not be(true)
        expect(@purchase.stripe_partially_refunded).to_not be(true)
        @purchase.refund_and_save!(@user.id, amount_cents: @purchase.total_transaction_cents - 10)
        @purchase.reload
        expect(@purchase.refunds.first.status).to eq("succeeded")
        expect(@purchase.stripe_refunded).to_not be(true)
        expect(@purchase.stripe_partially_refunded).to be(true)
      end

      it "refunds idempotent" do
        expect(ChargeProcessor).to_not receive(:refund!)
        @purchase.stripe_refunded = true
        @purchase.save!
        @purchase.refund_and_save!(@user.id, amount_cents: 10)
        @purchase.reload
        expect(@purchase.stripe_refunded).to_not be(false)
        expect(@purchase.stripe_partially_refunded).to_not be(true)
      end

      it "updates refund processor refund id" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        expect(@purchase.stripe_partially_refunded).to_not be(true)
        @purchase.refund_and_save!(@user.id, amount_cents: @purchase.total_transaction_cents - 10)
        @purchase.reload
        expect(@purchase.stripe_partially_refunded).to be(true)
        expect(@purchase.refunds.first.processor_refund_id).to_not be(nil)
      end

      it "allows refund multiple times" do
        expect(ChargeProcessor).to receive(:refund!).twice.with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        expect(@purchase.stripe_refunded).to_not be(true)
        expect(@purchase.stripe_partially_refunded).to_not be(true)
        @purchase.refund_and_save!(@user.id, amount_cents: @purchase.total_transaction_cents - 50)
        @purchase.reload
        expect(@purchase.refunds.first.status).to eq("succeeded")
        expect(@purchase.stripe_refunded).to_not be(true)
        expect(@purchase.stripe_partially_refunded).to be(true)

        @purchase.refund_and_save!(@user.id, amount_cents: 10)
        @purchase.reload
        expect(@purchase.stripe_partially_refunded).to be(true)
      end

      it "fully refunds if amount goes over total transaction cents" do
        expect(ChargeProcessor).to receive(:refund!).twice.with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        expect(@purchase.stripe_refunded).to_not be(true)
        expect(@purchase.stripe_partially_refunded).to_not be(true)
        @purchase.refund_and_save!(@user.id, amount_cents: @purchase.total_transaction_cents - 50)
        @purchase.reload
        expect(@purchase.refunds.first.status).to eq("succeeded")
        expect(@purchase.stripe_refunded).to_not be(true)
        expect(@purchase.stripe_partially_refunded).to be(true)

        @purchase.refund_and_save!(@user.id, amount_cents: 50)
        @purchase.reload
        expect(@purchase.stripe_partially_refunded).to_not be(true)
        expect(@purchase.stripe_refunded).to be(true)
      end

      it "updates balance of seller" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        @purchase.refund_and_save!(@user.id, amount_cents: 50)
        @user.reload
        verify_balance(@user, @initial_balance - @purchase.amount_refunded_cents + @purchase.fee_refunded_cents - @purchase.refunds.sum(&:retained_fee_cents))
        expect(@purchase.purchase_refund_balance).to eq @balance
      end

      it "updates balance of seller for multiple refunds" do
        expect(ChargeProcessor).to receive(:refund!).twice.with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        @purchase.refund_and_save!(@user.id, amount_cents: 10)
        @user.reload
        verify_balance(@user, @initial_balance - @purchase.amount_refunded_cents + @purchase.refunds.sum { |refund| refund.fee_cents - refund.retained_fee_cents })
        expect(@purchase.purchase_refund_balance).to eq @balance

        @purchase.reload

        @purchase.refund_and_save!(@user.id, amount_cents: 20)
        @user.reload
        verify_balance(@user, @initial_balance - @purchase.amount_refunded_cents + @purchase.refunds.sum { |refund| refund.fee_cents - refund.retained_fee_cents })
        expect(@purchase.purchase_refund_balance).to eq @balance
      end

      it "updates balance of seller for multiple refunds finally marking it as fully refunded" do
        expect(ChargeProcessor).to receive(:refund!).twice.with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        @purchase.refund_and_save!(@user.id, amount_cents: 10)
        @user.reload
        verify_balance(@user, @initial_balance - @purchase.amount_refunded_cents + @purchase.refunds.sum { |refund| refund.fee_cents - refund.retained_fee_cents })
        expect(@purchase.purchase_refund_balance).to eq @balance

        @purchase.reload

        @purchase.refund_and_save!(@user.id, amount_cents: 90)
        @user.reload
        @purchase.reload
        expect(@purchase.stripe_partially_refunded).to_not be(true)
        expect(@purchase.stripe_refunded).to be(true)
        verify_balance(@user, @initial_balance - @purchase.amount_refunded_cents + @purchase.refunds.sum { |refund| refund.fee_cents - refund.retained_fee_cents })
        expect(@purchase.purchase_refund_balance).to eq @balance
      end

      it "notifies customer about the refund" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        expect(CustomerMailer).to receive(:partial_refund).with(@purchase.email, @purchase.link.id, @purchase.id, 50, "partially").and_call_original
        @purchase.refund_and_save!(@user.id, amount_cents: 50)
      end

      it "reindexes ES document" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        ElasticsearchIndexerWorker.jobs.clear
        @purchase.refund_and_save!(@user.id, amount_cents: 50)
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", "record_id" => @purchase.id, "class_name" => "Purchase")
      end

      describe "with non USD currency" do
        before do
          @product = create(:product, user: @user, price_currency_type: :gbp, price_cents: 100)
          @purchase = create(:purchase_in_progress, link: @product, chargeable: create(:chargeable))
          @purchase.process!
          @purchase.mark_successful!
        end

        it "handles partial refunds with passed amount" do
          expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
          expect(@purchase.stripe_refunded).to_not be(true)
          expect(@purchase.stripe_partially_refunded).to_not be(true)
          expect(@purchase.refund_and_save!(@user.id, amount_cents: 50)).to be(true)
          @purchase.reload
          expect(@purchase.refunds.first.status).to eq("succeeded")
          expect(@purchase.stripe_refunded).to_not be(true)
          expect(@purchase.stripe_partially_refunded).to be(true)
        end

        describe "user has a merchant account" do
          let(:merchant_account) { create(:merchant_account_stripe_canada, user: @user) }

          it "creates a balance transaction for the refund" do
            charge_refund = nil
            original_charge_processor_refund = ChargeProcessor.method(:refund!)
            expect(ChargeProcessor).to receive(:refund!) do |*args, **kwargs|
              charge_refund = original_charge_processor_refund.call(*args, **kwargs)
              charge_refund
            end

            expect(@purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original
            expect(@purchase.stripe_refunded).to_not be(true)
            expect(@purchase.stripe_partially_refunded).to_not be(true)
            travel_to(Time.zone.local(2023, 10, 6)) do
              expect(@purchase.refund_and_save!(@user.id, amount_cents: 50)).to be(true)
            end
            @purchase.reload
            expect(@purchase.refunds.first.status).to eq("succeeded")
            expect(@purchase.stripe_refunded).to_not be(true)
            expect(@purchase.stripe_partially_refunded).to be(true)
            expect(@purchase.refunds.first.retained_fee_cents).to eq(4)

            flow_of_funds = charge_refund.flow_of_funds

            balance_transaction = BalanceTransaction.where.not(refund_id: nil).last
            expect(balance_transaction.user).to eq(@user)
            expect(balance_transaction.merchant_account).to eq(merchant_account)
            expect(balance_transaction.merchant_account).to eq(@purchase.merchant_account)
            expect(balance_transaction.refund).to eq(@purchase.refunds.last)
            expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
            expect(balance_transaction.issued_amount_currency).to eq(flow_of_funds.issued_amount.currency)
            expect(balance_transaction.issued_amount_gross_cents).to eq(-50)
            expect(balance_transaction.issued_amount_gross_cents).to eq(flow_of_funds.issued_amount.cents)
            expect(balance_transaction.issued_amount_net_cents).to eq(-18)
            expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
            expect(balance_transaction.holding_amount_currency).to eq(flow_of_funds.merchant_account_gross_amount.currency)
            expect(balance_transaction.holding_amount_currency).to eq(flow_of_funds.merchant_account_net_amount.currency)
            expect(balance_transaction.holding_amount_gross_cents).to eq(flow_of_funds.merchant_account_gross_amount.cents)
            expect(balance_transaction.holding_amount_net_cents).to eq(flow_of_funds.merchant_account_net_amount.cents)

            credit = @purchase.seller.credits.last
            expect(credit.amount_cents).to eq(-4)
          end
        end
      end
    end

    describe "user has a merchant account" do
      let(:merchant_account) { create(:merchant_account_stripe_canada, user: @user) }

      it "creates a balance transaction for the refund" do
        charge_refund = nil
        original_charge_processor_refund = ChargeProcessor.method(:refund!)
        expect(ChargeProcessor).to receive(:refund!) do |*args, **kwargs|
          charge_refund = original_charge_processor_refund.call(*args, **kwargs)
          charge_refund
        end

        travel_to(Time.zone.local(2023, 10, 6)) do
          @purchase.refund_and_save!(@user.id)
        end
        flow_of_funds = charge_refund.flow_of_funds

        balance_transaction = BalanceTransaction.where.not(refund_id: nil).last
        expect(balance_transaction.user).to eq(@user)
        expect(balance_transaction.merchant_account).to eq(merchant_account)
        expect(balance_transaction.merchant_account).to eq(@purchase.merchant_account)
        expect(balance_transaction.refund).to eq(@purchase.refunds.last)
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_currency).to eq(flow_of_funds.issued_amount.currency)
        expect(balance_transaction.issued_amount_gross_cents).to eq(-1 * @purchase.total_transaction_cents)
        expect(balance_transaction.issued_amount_gross_cents).to eq(flow_of_funds.issued_amount.cents)
        expect(balance_transaction.issued_amount_net_cents).to eq(-1 * @purchase.payment_cents)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction.holding_amount_currency).to eq(flow_of_funds.merchant_account_gross_amount.currency)
        expect(balance_transaction.holding_amount_currency).to eq(flow_of_funds.merchant_account_net_amount.currency)
        expect(balance_transaction.holding_amount_gross_cents).to eq(flow_of_funds.merchant_account_gross_amount.cents)
        expect(balance_transaction.holding_amount_net_cents).to eq(flow_of_funds.merchant_account_net_amount.cents)
      end

      it "updates balance of seller and # paid downloads" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        travel_to(Time.zone.local(2023, 10, 6)) do
          @purchase.refund_and_save!(@user.id)
        end
        @user.reload
        verify_balance(@user, @initial_balance - @purchase.price_cents + @purchase.fee_cents - @purchase.processor_fee_cents)
        expect(@purchase.purchase_refund_balance).to eq @balance
        @product.reload
        expect(@product.sales.paid.count).to_not eq @initial_num_paid_download
        @product.sales.paid.count == @initial_num_paid_download - 1
      end

      it "does not try to reverse the associated transfer if purchase is chargedback and chargeback is won" do
        purchase = create(:purchase, link: @product, charge_processor_id: "stripe", stripe_transaction_id: "ch_2O4xEq9e1RjUNIyY0XEY66sA",
                                     merchant_account:, price_cents: 10_00)
        purchase.chargeback_date = Date.today
        purchase.chargeback_reversed = true
        purchase.save!

        charge_refund = nil
        original_stripe_refund = Stripe::Refund.method(:create)
        expect(Stripe::Refund).to receive(:create).with({ charge: purchase.stripe_transaction_id }) do |*args|
          charge_refund = original_stripe_refund.call(*args)
          charge_refund
        end

        expect(ChargeProcessor).to receive(:refund!).with(purchase.charge_processor_id, purchase.stripe_transaction_id,
                                                          amount_cents: nil, merchant_account: purchase.merchant_account,
                                                          reverse_transfer: false, paypal_order_purchase_unit_refund: nil,
                                                          is_for_fraud: false).and_call_original
        expect(purchase).to receive(:debit_processor_fee_from_merchant_account!)

        purchase.refund_and_save!(create(:admin_user).id)

        expect(charge_refund.transfer_reversal).to be nil
      end
    end

    describe "user has a merchant account not charge processor alive" do
      let(:merchant_account) { create(:merchant_account_stripe_canada, user: @user, charge_processor_alive_at: nil) }

      it "creates a balance transaction for the refund" do
        charge_refund = nil
        original_charge_processor_refund = ChargeProcessor.method(:refund!)
        expect(ChargeProcessor).to receive(:refund!) do |*args, **kwargs|
          charge_refund = original_charge_processor_refund.call(*args, **kwargs)
          charge_refund
        end

        @purchase.refund_and_save!(@user.id)
        flow_of_funds = charge_refund.flow_of_funds

        balance_transaction = BalanceTransaction.where.not(refund_id: nil).last
        expect(balance_transaction.user).to eq(@user)
        expect(balance_transaction.merchant_account).not_to eq(merchant_account)
        expect(balance_transaction.merchant_account).to eq(@purchase.merchant_account)
        expect(balance_transaction.refund).to eq(@purchase.refunds.last)
        expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.issued_amount_currency).to eq(flow_of_funds.issued_amount.currency)
        expect(balance_transaction.issued_amount_gross_cents).to eq(-1 * @purchase.total_transaction_cents)
        expect(balance_transaction.issued_amount_gross_cents).to eq(flow_of_funds.issued_amount.cents)
        expect(balance_transaction.issued_amount_net_cents).to eq(-1 * @purchase.payment_cents)
        expect(balance_transaction.holding_amount_currency).to eq(Currency::USD)
        expect(balance_transaction.holding_amount_currency).to eq(flow_of_funds.issued_amount.currency)
        expect(balance_transaction.holding_amount_gross_cents).to eq(-1 * @purchase.total_transaction_cents)
        expect(balance_transaction.holding_amount_gross_cents).to eq(flow_of_funds.issued_amount.cents)
        expect(balance_transaction.holding_amount_net_cents).to eq(-1 * @purchase.payment_cents)
      end
    end

    it "refunds successfully a single purchase which is part of a combined charge on a non-usd PayPal merchant account" do
      merchant_account = create(:merchant_account_paypal, user: @product.user, charge_processor_merchant_id: "HXQPE2F4AZ494", currency: "cad")
      purchase = build(:purchase, link: @product, merchant_account:,
                                  paypal_order_id: "0BX01387XY3573432",
                                  stripe_transaction_id: "5HR31200C31692256",
                                  charge_processor_id: "paypal")
      purchase.charge = create(:charge, processor_transaction_id: purchase.stripe_transaction_id)
      expect(purchase.merchant_account_id).to eq(merchant_account.id)
      expect(purchase.charge.purchases.many?).to be false

      purchase.refund!(refunding_user_id: purchase.seller.id)

      expect(purchase.stripe_refunded?).to be true
      expect(purchase.refunds.last.amount_cents).to eq(purchase.total_transaction_cents)
    end

    it "works when link is sold out" do
      link = create(:product, max_purchase_count: 1)
      purchase = create(:purchase, link:, seller: link.user)
      expect(-> { purchase.refund_and_save!(link.user.id) }).to_not raise_error
    end

    it "creates a refund event" do
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
      calculated_fingerprint = "3dfakl93klfdjsa09rn"
      allow(Digest::MD5).to receive(:hexdigest).and_return(calculated_fingerprint)
      @purchase.refund_and_save!(@user.id)
      expect(Event.last.event_name).to eq "refund"
      expect(@purchase.reload.is_refund_chargeback_fee_waived).to be(false)
    end

    it "creates a refund object" do
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
      calculated_fingerprint = "3dfakl93klfdjsa09rn"
      allow(Digest::MD5).to receive(:hexdigest).and_return(calculated_fingerprint)
      @purchase.refund_and_save!(@user.id)
      expect(Refund.last.purchase).to eq @purchase
      expect(Refund.last.amount_cents).to eq @purchase.price_cents
      expect(Refund.last.refunding_user_id).to eq @user.id
    end

    it "returns true if refunds without error" do
      expect(ChargeProcessor).to receive(:refund!).and_call_original
      expect(@purchase.refund_and_save!(@user.id)).to be(true)
    end

    it "returns false if charge processor indicates request invalid" do
      expect(ChargeProcessor).to receive(:refund!).and_raise(ChargeProcessorInvalidRequestError)
      expect(@purchase.refund_and_save!(@user.id)).to be(false)
    end

    it "returns false if charge processor unavailable" do
      expect(ChargeProcessor).to receive(:refund!).and_raise(ChargeProcessorUnavailableError)
      expect(@purchase.refund_and_save!(@user.id)).to be(false)
    end

    it "returns false if charge processor indicates already refunded" do
      expect(ChargeProcessor).to receive(:refund!).and_raise(ChargeProcessorAlreadyRefundedError)
      expect(@purchase.refund_and_save!(@user.id)).to be(false)
    end

    describe "refund with tax" do
      describe "with sales tax" do
        before do
          @purchase = create(:purchase_in_progress, link: @product, chargeable: create(:chargeable))
          @purchase.process!
          @purchase.mark_successful!
          @purchase.tax_cents = 16
          @purchase.save!
        end

        it "refunds total transaction amount" do
          expect(@purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original

          expect(@purchase.refund_and_save!(@user.id)).to be(true)
          expect(Refund.last.purchase).to eq @purchase
          expect(Refund.last.amount_cents).to eq @purchase.price_cents
          expect(Refund.last.creator_tax_cents).to eq @purchase.tax_cents
          expect(Refund.last.gumroad_tax_cents).to eq @purchase.gumroad_tax_cents
        end


        it "refunds with given amount cents" do
          expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
          expect(@purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original

          expect(@purchase.refund_and_save!(@user.id, amount_cents: 50)).to be(true)
          refund = Refund.last
          expect(refund.purchase).to eq @purchase
          expect(refund.amount_cents).to eq 50
          expect(refund.total_transaction_cents).to eq(50) # 42 + 8 creator tax cents
          expect(refund.creator_tax_cents).to eq 8
          expect(refund.gumroad_tax_cents).to eq 0
        end
      end
    end

    describe "refunds with vat" do
      before do
        @zip_tax_rate = create(:zip_tax_rate, combined_rate: 0.20, is_seller_responsible: false, country: "AT", state: nil, zip_code: nil)

        seller = @product.user
        seller.zip_tax_rates << @zip_tax_rate
        seller.save!

        @purchase = create(:purchase_in_progress, link: @product, zip_tax_rate: @zip_tax_rate, chargeable: create(:chargeable), country: "Austria")
        @purchase.process!
        @purchase.mark_successful!
      end

      it "refunds total transaction amount" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        expect(@purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original

        expect(@purchase.refund_and_save!(@user.id)).to be(true)
        expect(Refund.last.purchase).to eq @purchase
        expect(Refund.last.amount_cents).to eq @purchase.price_cents
        expect(Refund.last.total_transaction_cents).to eq(@purchase.price_cents + @purchase.gumroad_tax_cents)
        expect(Refund.last.creator_tax_cents).to eq @purchase.tax_cents
        expect(Refund.last.gumroad_tax_cents).to eq @purchase.gumroad_tax_cents
      end

      it "refunds with given amount cents" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        expect(@purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original

        expect(@purchase.refund_and_save!(@user.id, amount_cents: 50)).to be(true)
        refund = Refund.last
        expect(refund.purchase).to eq @purchase
        expect(refund.amount_cents).to eq 50
        expect(refund.total_transaction_cents).to eq(60) # 50 + 10 gumroad vat tax cents
        expect(refund.creator_tax_cents).to eq 0
        expect(refund.gumroad_tax_cents).to eq 10

        stripe_refund = Stripe::Refund.retrieve(refund.processor_refund_id)
        expect(stripe_refund.amount).to eq 60
      end

      it "refunds with given amount_refundable_cents" do
        expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
        amount_refundable_cents = @purchase.amount_refundable_cents
        total_transaction_cents = @purchase.total_transaction_cents
        expect(@purchase.refund_and_save!(@user.id, amount_cents: @purchase.amount_refundable_cents)).to be(true)
        refund = Refund.last
        expect(refund.purchase).to eq @purchase
        expect(refund.amount_cents).to eq amount_refundable_cents
        expect(refund.total_transaction_cents).to eq total_transaction_cents
        expect(refund.creator_tax_cents).to eq 0
        expect(refund.gumroad_tax_cents).to eq(total_transaction_cents - amount_refundable_cents)
      end

      describe "refund Gumroad taxes" do
        it "refunds all taxes collected by Gumroad" do
          expect(ChargeProcessor).to receive(:refund!)
                                         .with(@purchase.charge_processor_id, @purchase.stripe_transaction_id,
                                               amount_cents: 20,
                                               reverse_transfer: false,
                                               merchant_account: @purchase.merchant_account,
                                               paypal_order_purchase_unit_refund: false)
                                         .and_call_original
          expect(@purchase).not_to receive(:debit_processor_fee_from_merchant_account!).and_call_original

          @purchase.refund_gumroad_taxes!(refunding_user_id: @product.user.id, note: "VAT_ID_1234_Dummy")

          expect(Refund.last.purchase).to eq @purchase
          expect(Refund.last.refunding_user_id).to eq @product.user.id
          expect(Refund.last.amount_cents).to eq 0
          expect(Refund.last.total_transaction_cents).to eq 20
          expect(Refund.last.creator_tax_cents).to eq 0
          expect(Refund.last.gumroad_tax_cents).to eq 20
          expect(Refund.last.note).to eq "VAT_ID_1234_Dummy"
          expect(Refund.last.processor_refund_id).to be_present
          expect(@purchase.reload.stripe_refunded).to be(false)
        end

        it "does not deduct the refunded tax amount from the connect account" do
          merchant_account = create(:merchant_account_stripe_canada, user: @user)
          purchase = create(:purchase_in_progress, link: @product, zip_tax_rate: @zip_tax_rate, chargeable: create(:chargeable))
          purchase.process!
          purchase.mark_successful!
          purchase.gumroad_tax_cents = 20
          purchase.total_transaction_cents = purchase.gumroad_tax_cents + purchase.price_cents
          purchase.save!
          expect(purchase.merchant_account).to eq(merchant_account)

          charge_refund = nil
          original_stripe_refund = Stripe::Refund.method(:create)
          expect(Stripe::Refund).to receive(:create).with({ charge: purchase.stripe_transaction_id, amount: 20 }) do |*args|
            charge_refund = original_stripe_refund.call(*args)
            charge_refund
          end

          purchase.refund_gumroad_taxes!(refunding_user_id: purchase.seller.id, note: "VAT_ID_1234_Dummy")

          expect(charge_refund.transfer_reversal).to be nil
        end

        it "does not refund in excess if Gumroad taxes were already refunded - full refund" do
          expect(ChargeProcessor).to receive(:refund!)
                                         .with(@purchase.charge_processor_id,
                                               @purchase.stripe_transaction_id,
                                               amount_cents: 20,
                                               reverse_transfer: false,
                                               merchant_account: @purchase.merchant_account,
                                               paypal_order_purchase_unit_refund: false).and_call_original

          @purchase.refund_gumroad_taxes!(refunding_user_id: nil)

          expect(Refund.last.purchase).to eq @purchase
          expect(Refund.last.amount_cents).to eq 0
          expect(Refund.last.total_transaction_cents).to eq 20
          expect(Refund.last.creator_tax_cents).to eq 0
          expect(Refund.last.gumroad_tax_cents).to eq 20
          expect(@purchase.reload.stripe_refunded).to be(false)

          expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original

          expect(@purchase.refund_and_save!(@user.id)).to be(true)

          remaining_refund_price_cents = @purchase.total_transaction_cents - @purchase.gumroad_tax_cents
          expect(Refund.last.purchase).to eq @purchase
          expect(Refund.last.amount_cents).to eq remaining_refund_price_cents
          expect(Refund.last.total_transaction_cents).to eq remaining_refund_price_cents
          expect(Refund.last.creator_tax_cents).to eq 0
          expect(Refund.last.gumroad_tax_cents).to eq 0
          expect(@purchase.reload.stripe_refunded).to be(true)
        end

        it "does not refund anything if purchase is already refunded" do
          expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original

          expect(@purchase.refund_and_save!(@user.id)).to be(true)

          refund_count = Refund.count

          expect(ChargeProcessor).to_not receive(:refund!)
          @purchase.refund_gumroad_taxes!(refunding_user_id: nil)

          expect(Refund.count).to eq(refund_count)
        end

        it "does not refund anything if purchase already stripe refunded" do
          @purchase.stripe_refunded = true
          @purchase.save!
          refund_count = Refund.count

          expect(ChargeProcessor).to_not receive(:refund!)
          @purchase.refund_gumroad_taxes!(refunding_user_id: nil)

          expect(Refund.count).to eq(refund_count)
        end

        it "saves business vat id along with refund information" do
          @purchase.refund_gumroad_taxes!(refunding_user_id: @product.user.id, note: "Sample Note", business_vat_id: "IE6388047V")

          refund = Refund.last
          expect(refund.purchase).to eq @purchase
          expect(refund.refunding_user_id).to eq @product.user.id
          expect(refund.amount_cents).to eq 0
          expect(refund.total_transaction_cents).to eq 20
          expect(refund.creator_tax_cents).to eq 0
          expect(refund.gumroad_tax_cents).to eq 20
          expect(refund.note).to eq "Sample Note"
          expect(refund.business_vat_id).to eq "IE6388047V"
        end

        describe "PayPal Connect sales" do
          before do
            ZipTaxRate.find_or_create_by(country: "GB").update(combined_rate: 0.20)
            merchant_account = create(:merchant_account_paypal, user: @product.user,
                                                                charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")
            @paypal_purchase = create(:purchase, link: @product, purchase_state: "in_progress",
                                                 chargeable: create(:native_paypal_chargeable), country: Compliance::Countries::GBR.common_name,
                                                 ip_country: Compliance::Countries::GBR.common_name)
            @paypal_purchase.process!
            @paypal_purchase.update_balance_and_mark_successful!
            expect(@paypal_purchase.reload.successful?).to be true
            expect(@paypal_purchase.charge_processor_id).to eq PaypalChargeProcessor.charge_processor_id
            expect(@paypal_purchase.merchant_account).to eq merchant_account
            expect(@paypal_purchase.gumroad_tax_cents).to eq 20
          end

          describe "refund Gumroad taxes" do
            context "when purchase is NOT partially refunded" do
              before do
                expect(ChargeProcessor).to receive(:refund!)
                                             .with(@paypal_purchase.charge_processor_id, @paypal_purchase.stripe_transaction_id,
                                                   amount_cents: 20,
                                                   reverse_transfer: false,
                                                   merchant_account: @paypal_purchase.merchant_account,
                                                   paypal_order_purchase_unit_refund: true)
                                             .and_call_original
              end

              it "refunds all taxes collected by Gumroad" do
                @paypal_purchase.refund_gumroad_taxes!(refunding_user_id: @product.user.id, note: "VAT_ID_1234_Dummy")

                expect(Refund.last.purchase).to eq @paypal_purchase
                expect(Refund.last.refunding_user_id).to eq @product.user.id
                expect(Refund.last.amount_cents).to eq 0
                expect(Refund.last.total_transaction_cents).to eq 20
                expect(Refund.last.creator_tax_cents).to eq 0
                expect(Refund.last.gumroad_tax_cents).to eq 20
                expect(Refund.last.note).to eq "VAT_ID_1234_Dummy"
                expect(Refund.last.processor_refund_id).to be_present
                expect(@paypal_purchase.reload.stripe_refunded).to be(false)
              end

              it "credits the creator account with the refunded VAT amount minus the fee that is returned" do
                expect do
                  expect do
                    @paypal_purchase.refund_gumroad_taxes!(refunding_user_id: @product.user.id, note: "VAT_ID_1234_Dummy")
                  end.to change { Credit.count }.by(1)
                end.to change { @paypal_purchase.seller.comments.count }.by(1)

                expect(Credit.last.refund.purchase).to eq(@paypal_purchase)
                expect(Credit.last.amount_cents).to eq 7
                expect(@paypal_purchase.seller.comments.last.author_name).to eq "AutoCredit PayPal Connect VAT refund (#{@paypal_purchase.id})"
              end
            end

            context "when purchase is partially refunded" do
              before do
                expect(@paypal_purchase.amount_refundable_cents).to eq(100)
                expect(@paypal_purchase.gumroad_tax_refundable_cents).to eq(20)

                @paypal_purchase.refund_and_save!(@product.user_id, amount_cents: @paypal_purchase.price_cents / 2)

                expect(@paypal_purchase.amount_refundable_cents).to eq(50)
                expect(@paypal_purchase.gumroad_tax_refundable_cents).to eq(10)
              end

              it "refunds only the remaining taxes" do
                @paypal_purchase.refund_gumroad_taxes!(refunding_user_id: @product.user_id, note: "VAT_ID_1234_Dummy")

                expect(Refund.last.purchase).to eq @paypal_purchase
                expect(Refund.last.refunding_user_id).to eq @product.user.id
                expect(Refund.last.amount_cents).to eq 0
                expect(Refund.last.total_transaction_cents).to eq 10
                expect(Refund.last.creator_tax_cents).to eq 0
                expect(Refund.last.gumroad_tax_cents).to eq 10
                expect(Refund.last.note).to eq "VAT_ID_1234_Dummy"
                expect(Refund.last.processor_refund_id).to be_present
                expect(@paypal_purchase.reload.stripe_refunded).to be(false)
                expect(@paypal_purchase.reload.gumroad_tax_refundable_cents).to eq(0)
              end
            end
          end

          describe "further refunds after refunding Gumroad taxes" do
            context "when gumroad taxes have NOT been refunded" do
              it "does not debit the creator's account" do
                expect do
                  @paypal_purchase.refund_and_save!(@product.user_id)
                end.not_to change { Credit.count }
              end
            end

            context "when gumroad taxes have been refunded" do
              before do
                expect do
                  @paypal_purchase.refund_gumroad_taxes!(refunding_user_id: @product.user_id, note: "VAT_ID_1234_Dummy")
                end.to change { Credit.count }.by(1)
                expect(Credit.last.amount_cents).to eq 7
              end

              it "debits the creator account with the same amount that was credited during gumroad VAT refund" do
                expect do
                  expect do
                    @paypal_purchase.refund_and_save!(@product.user_id, amount_cents: @paypal_purchase.price_cents / 2)
                  end.to change { Credit.count }.by(1)
                end.to change { @paypal_purchase.seller.comments.count }.by(1)

                expect(Credit.last.refund.purchase).to eq(@paypal_purchase)
                expect(Credit.last.amount_cents).to eq(-3)
                expect(@paypal_purchase.seller.comments.last(2).first.author_name).to eq "AutoCredit PayPal Connect VAT refund (#{@paypal_purchase.id})"

                # Follow-up with a full refund
                expect do
                  @paypal_purchase.refund_and_save!(@product.user_id)
                end.to change { Credit.count }.by(1)

                expect(Credit.last.refund.purchase).to eq(@paypal_purchase)
                expect(Credit.last.amount_cents).to eq(-3)

                # None of the refunded amount is attributed to taxes since VAT was refunded separately
                refund = Refund.last
                expect(refund.amount_cents).to eq @paypal_purchase.price_cents / 2
                expect(refund.total_transaction_cents).to eq @paypal_purchase.price_cents / 2
                expect(refund.gumroad_tax_cents).to eq 0
              end
            end
          end
        end
      end
    end

    describe "do not decrement seller balance twice" do
      let(:purchase) do
        purchase = create(:purchase_in_progress, chargeable: create(:chargeable))
        purchase.process!
        purchase.update_balance_and_mark_successful!
        purchase
      end

      let(:charge_event_dispute) { build(:charge_event_dispute_formalized, charge_id: purchase.stripe_transaction_id) }

      describe "refund after a dispute event which is functionally treated as a chargeback on our side" do
        before do
          Purchase.handle_charge_event(charge_event_dispute)
          expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
          purchase.reload
        end

        it "does not decrement balance from the user on such an event" do
          expect(purchase).to_not receive(:process_refund_or_chargeback_for_purchase_balance)
          expect(purchase).to_not receive(:process_refund_or_chargeback_for_affiliate_credit_balance)

          purchase.refund_and_save!(create(:admin_user).id)
        end
      end

      describe "dispute after a refund event does not decrement seller balance" do
        before do
          purchase.refund_and_save!(create(:admin_user).id)
        end

        it "does not decrement balance from the user on such an event" do
          expect(purchase).to_not receive(:process_refund_or_chargeback_for_purchase_balance)
          expect(purchase).to_not receive(:process_refund_or_chargeback_for_affiliate_credit_balance)

          Purchase.handle_charge_event(charge_event_dispute)
          expect(FightDisputeJob).to have_enqueued_sidekiq_job(purchase.dispute.id)
        end
      end
    end

    it "calls 'send_refunded_notification_webhook' to send sale refunded notification to the seller" do
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original
      expect(@purchase.stripe_refunded).to be(false)
      expect(@purchase).to receive(:send_refunded_notification_webhook)

      @purchase.refund_and_save!(@user.id)

      expect(@purchase.reload.stripe_refunded).to be(true)
    end

    context "when refunds are disabled for the creator" do
      before do
        @user.disable_refunds!
      end

      context "when the refunding user is not an admin"  do
        it "doesn't issue a refund" do
          expect(ChargeProcessor).to_not receive(:refund!)

          @purchase.refund_and_save!(@user.id)

          expect(@purchase.errors[:base].first).to eq "Refunds are temporarily disabled in your account."
        end
      end

      context "when the refunding user is an admin" do
        before do
          @admin_user = create(:admin_user)
        end

        it "issues a refund" do
          expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, anything).and_call_original

          @purchase.refund_and_save!(@admin_user.id)
        end
      end
    end

    context "when creator's balance is less than the refund amount", :vcr do
      let(:purchase) { create(:purchase_in_progress, link: create(:product, user: @user, price_cents: 25_00)) }

      before do
        allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(10_00)
      end

      context "when the refunding user is not an admin"  do
        it "doesn't issue a refund if the purchase was made on Gumroad's Stripe account" do
          purchase.chargeable = create(:chargeable, product_permalink: purchase.link.unique_permalink)
          purchase.process!
          expect(purchase.merchant_account).to eq(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
          purchase.mark_successful!

          expect(ChargeProcessor).to_not receive(:refund!)
          purchase.reload.refund_and_save!(@user.id)
          expect(purchase.errors[:base].first).to eq "Your balance is insufficient to process this refund."
          expect(purchase.reload.stripe_refunded).to be false
          expect(purchase.refunds.last).to be nil
        end

        it "doesn't issue a refund if the purchase was made on Gumroad-managed Stripe account" do
          stripe_account = create(:merchant_account_stripe, user: @user)
          purchase.chargeable = create(:chargeable, product_permalink: purchase.link.unique_permalink)
          purchase.process!
          expect(purchase.merchant_account).to eq(stripe_account)
          purchase.mark_successful!

          expect(ChargeProcessor).to_not receive(:refund!)
          purchase.reload.refund_and_save!(@user.id)
          expect(purchase.errors[:base].first).to eq "Your balance is insufficient to process this refund."
          expect(purchase.reload.stripe_refunded).to be false
          expect(purchase.refunds.last).to be nil
        end

        it "issues a refund if the purchase was made on creator's Stripe Connect account" do
          @user.update!(check_merchant_account_is_linked: true)
          stripe_connect_account = create(:merchant_account_stripe_connect, user: @user)
          purchase.chargeable = create(:chargeable, product_permalink: purchase.link.unique_permalink)
          purchase.process!
          expect(purchase.merchant_account).to eq(stripe_connect_account)
          purchase.mark_successful!
          expect(ChargeProcessor).to receive(:refund!).with(purchase.charge_processor_id, purchase.stripe_transaction_id, anything).and_call_original

          purchase.reload.refund_and_save!(@user.id)
          expect(purchase.errors[:base].first).to be nil
          expect(purchase.reload.stripe_refunded).to be true
          expect(purchase.refunds.last.total_transaction_cents).to eq(25_00)
          expect(purchase.refunds.last.processor_refund_id).to be_present
        end

        it "issues a partial refund if the refund amount is not more than creator's balance" do
          stripe_account = create(:merchant_account_stripe, user: @user)
          purchase.chargeable = create(:chargeable, product_permalink: purchase.link.unique_permalink)
          purchase.process!
          expect(purchase.merchant_account).to eq(stripe_account)
          purchase.mark_successful!

          expect(ChargeProcessor).to receive(:refund!).with(purchase.charge_processor_id, purchase.stripe_transaction_id, anything).and_call_original
          purchase.reload.refund_and_save!(@user.id, amount_cents: 10_00)
          expect(purchase.errors[:base].first).to be nil
          expect(purchase.reload.stripe_partially_refunded).to be true
          expect(purchase.reload.stripe_refunded).to be false
          expect(purchase.refunds.last.total_transaction_cents).to eq(10_00)
          expect(purchase.refunds.last.processor_refund_id).to be_present
        end
      end

      context "when the refunding user is an admin" do
        let(:admin_user) { create(:admin_user) }

        it "issues a refund if the purchase was made on Gumroad's Stripe account" do
          purchase.chargeable = create(:chargeable, product_permalink: purchase.link.unique_permalink)
          purchase.process!
          expect(purchase.merchant_account).to eq(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id))
          purchase.mark_successful!

          expect(ChargeProcessor).to receive(:refund!).with(purchase.charge_processor_id, purchase.stripe_transaction_id, anything).and_call_original
          purchase.reload.refund_and_save!(admin_user.id)
          expect(purchase.errors[:base].first).to be nil
          expect(purchase.reload.stripe_refunded).to be true
          expect(purchase.refunds.last.total_transaction_cents).to eq(25_00)
          expect(purchase.refunds.last.processor_refund_id).to be_present
        end

        it "issues a refund if the purchase was made on Gumroad-managed Stripe account" do
          stripe_account = create(:merchant_account_stripe, user: @user)
          purchase.chargeable = create(:chargeable, product_permalink: purchase.link.unique_permalink)
          purchase.process!
          expect(purchase.merchant_account).to eq(stripe_account)
          purchase.mark_successful!

          expect(ChargeProcessor).to receive(:refund!).with(purchase.charge_processor_id, purchase.stripe_transaction_id, anything).and_call_original
          purchase.reload.refund_and_save!(admin_user.id)
          expect(purchase.errors[:base].first).to be nil
          expect(purchase.reload.stripe_refunded).to be true
          expect(purchase.refunds.last.total_transaction_cents).to eq(25_00)
          expect(purchase.refunds.last.processor_refund_id).to be_present
        end

        it "issues a refund if the purchase was made on creator's Stripe Connect account" do
          @user.update!(check_merchant_account_is_linked: true)
          stripe_connect_account = create(:merchant_account_stripe_connect, user: @user)
          purchase.chargeable = create(:chargeable, product_permalink: purchase.link.unique_permalink)
          purchase.process!
          expect(purchase.merchant_account).to eq(stripe_connect_account)
          purchase.mark_successful!
          expect(ChargeProcessor).to receive(:refund!).with(purchase.charge_processor_id, purchase.stripe_transaction_id, anything).and_call_original

          purchase.reload.refund_and_save!(admin_user.id)
          expect(purchase.errors[:base].first).to be nil
          expect(purchase.reload.stripe_refunded).to be true
          expect(purchase.refunds.last.total_transaction_cents).to eq(25_00)
          expect(purchase.refunds.last.processor_refund_id).to be_present
        end
      end
    end

    describe "partial refund after vat refund" do
      before do
        create(:zip_tax_rate, country: "DE", combined_rate: 0.2, flags: 0)
        @product = create(:product, price_cents: 1000)
        @merchant_account = create(:merchant_account, user: @product.user, country: "CA", currency: "cad",
                                                      charge_processor_merchant_id: "acct_1MbQQ6S2yTRm7HHQ")
        stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
      end

      it "does not try to create a transfer reversal if purchase does not have vat already refunded" do
        purchase = build(:purchase_in_progress, link: @product, gumroad_tax_cents: 200, country: "Germany", ip_country: "Germany", chargeable: create(:chargeable))
        purchase.process!
        purchase.update_balance_and_mark_successful!
        expect(purchase.reload.merchant_account_id).to eq(@merchant_account.id)
        expect(purchase.gumroad_tax_cents).to eq(200)

        expect_any_instance_of(Purchase).to_not receive(:reverse_excess_amount_from_stripe_transfer)

        purchase.refund!(refunding_user_id: purchase.seller.id, amount: 500)
      end

      it "does not try to create a transfer reversal if this is not a partial refund" do
        purchase = build(:purchase_in_progress, link: @product, gumroad_tax_cents: 200, country: "Germany", ip_country: "Germany", chargeable: create(:chargeable))
        purchase.process!
        purchase.update_balance_and_mark_successful!
        expect(purchase.merchant_account_id).to eq(@merchant_account.id)
        expect(purchase.gumroad_tax_cents).to eq(200)

        purchase.refund_gumroad_taxes!(refunding_user_id: purchase.seller.id, note: "dummy_note", business_vat_id: "dummy_vat_id")
        expect(purchase.gumroad_tax_refunded_cents).to eq(purchase.gumroad_tax_cents)

        expect_any_instance_of(Purchase).to_not receive(:reverse_excess_amount_from_stripe_transfer)

        travel_to(Time.zone.local(2023, 11, 27)) do
          purchase.refund!(refunding_user_id: purchase.seller.id)
        end
      end

      it "does not try to create a transfer reversal if holder of funds is not Stripe" do
        merchant_account = create(:merchant_account_paypal, user: @product.user, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")
        purchase = build(:purchase_in_progress, link: @product, gumroad_tax_cents: 200, country: "Germany", ip_country: "Germany", chargeable: create(:native_paypal_chargeable))
        purchase.process!
        purchase.update_balance_and_mark_successful!
        expect(purchase.merchant_account_id).to eq(merchant_account.id)
        expect(purchase.gumroad_tax_cents).to eq(200)

        purchase.reload.refund_gumroad_taxes!(refunding_user_id: purchase.seller.id, note: "dummy_note", business_vat_id: "dummy_vat_id")
        expect(purchase.gumroad_tax_refunded_cents).to eq(purchase.gumroad_tax_cents)

        expect_any_instance_of(Purchase).to_not receive(:reverse_excess_amount_from_stripe_transfer)

        purchase.refund!(refunding_user_id: purchase.seller.id, amount: 500)
      end

      it "reverses the correct amount from the transfer in case of partial refund on a stripe purchase with vat already refunded" do
        purchase = build(:purchase_in_progress, link: @product, gumroad_tax_cents: 200, country: "Germany", ip_country: "Germany", chargeable: create(:chargeable))
        purchase.process!
        purchase.update_balance_and_mark_successful!
        expect(purchase.merchant_account_id).to eq(@merchant_account.id)
        expect(purchase.gumroad_tax_cents).to eq(200)

        purchase.refund_gumroad_taxes!(refunding_user_id: purchase.seller.id, note: "dummy_note", business_vat_id: "dummy_vat_id")
        expect(purchase.gumroad_tax_refunded_cents).to eq(purchase.gumroad_tax_cents)

        expect_any_instance_of(Purchase).to receive(:reverse_excess_amount_from_stripe_transfer).and_call_original
        expect(Stripe::Transfer).to receive(:create_reversal).twice.and_call_original
        expect(Credit).to receive(:create_for_partial_refund_transfer_reversal!).with(amount_cents_usd: -29,
                                                                                      amount_cents_holding_currency: -100,
                                                                                      merchant_account: @merchant_account).and_call_original

        travel_to(Time.zone.local(2023, 11, 27)) do
          purchase.refund!(refunding_user_id: purchase.seller.id, amount: 5)
        end

        credit = Credit.last(2).first
        balance_transaction = credit.balance_transaction
        expect(credit.user).to eq(@product.user)
        expect(credit.amount_cents).to eq(-29)
        expect(credit.merchant_account).to eq(@merchant_account)
        expect(balance_transaction.user).to eq(@product.user)
        expect(balance_transaction.merchant_account).to eq(@merchant_account)
        expect(balance_transaction.issued_amount_currency).to eq("usd")
        expect(balance_transaction.issued_amount_net_cents).to eq(-29)
        expect(balance_transaction.holding_amount_currency).to eq("cad")
        expect(balance_transaction.holding_amount_net_cents).to eq(-100)
      end
    end
  end

  describe "#reverse_excess_amount_from_stripe_transfer" do
    before do
      @product = create(:product, price_cents: 1000)
      @merchant_account = create(:merchant_account, user: @product.user, country: "CA", currency: "cad",
                                                    charge_processor_merchant_id: "acct_1MbQQ6S2yTRm7HHQ")
    end

    it "does not try to create a transfer reversal if total amount to be reversed is already reversed" do
      purchase = create(:purchase, link: @product, merchant_account: @merchant_account, stripe_transaction_id: "ch_2MlrJr9e1RjUNIyY0s8AWM5s")
      allow_any_instance_of(Purchase).to receive(:gumroad_tax_cents).and_return 200
      allow_any_instance_of(Purchase).to receive(:gumroad_tax_refunded_cents).and_return 200
      expect(Stripe::Charge).to receive(:retrieve).and_call_original
      expect(Stripe::Transfer).to receive(:retrieve).and_call_original

      refund = create(:refund, purchase:, processor_refund_id: "re_2MlrJr9e1RjUNIyY0dzjVFPd")

      BalanceTransaction.create!(
        user: purchase.seller,
        merchant_account: purchase.merchant_account,
        refund:,
        dispute: nil,
        issued_amount: BalanceTransaction::Amount.new(currency: "usd", gross_cents: -500, net_cents: -367),
        holding_amount: BalanceTransaction::Amount.new(currency: "cad", gross_cents: -492, net_cents: -492),
        update_user_balance: purchase.charged_using_gumroad_merchant_account?
      )

      expect(Stripe::Transfer).not_to receive(:create_reversal)

      purchase.send(:reverse_excess_amount_from_stripe_transfer, refund:)
    end
  end

  describe "refund subscription purchase" do
    describe "excluding reviews on subscription charges" do
      let(:subscriber) { create(:user, credit_card: create(:credit_card)) }

      describe "free trial subscription" do
        let(:original_purchase) { create(:free_trial_membership_purchase, purchaser: subscriber, price_cents: 100) }
        let!(:first_charge) { original_purchase.subscription.charge! }

        it "excludes the subscriber's review when refunding the first charge" do
          expect do
            first_charge.refund_and_save!(create(:admin_user).id)
          end.to change { original_purchase.reload.should_exclude_product_review? }.from(false).to(true)
        end

        it "does not exclude the subscriber's review when refunding a subsequent charge" do
          travel_to original_purchase.subscription.end_time_of_subscription + 1.hour do
            second_charge = original_purchase.subscription.charge!
            expect do
              second_charge.refund_and_save!(original_purchase.seller_id)
            end.not_to change { original_purchase.reload.should_exclude_product_review? }
          end
        end
      end

      describe "non-free trial subscription" do
        let(:original_purchase) { create(:membership_purchase, purchaser: subscriber, price_cents: 100) }
        let!(:first_charge) { original_purchase.subscription.charge! }

        it "does not exclude the subscriber's review" do
          expect do
            first_charge.refund_and_save!(original_purchase.seller_id)
          end.not_to change { original_purchase.reload.should_exclude_product_review? }
        end
      end
    end
  end

  describe "#refund_purchase!" do
    before do
      @purchase = create(:purchase)
      @refunding_user = create(:user)
    end

    it "enqueues a UpdateSellerRefundEligibilityJob" do
      flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase.price_cents)
      expect do
        @purchase.refund_purchase!(flow_of_funds, @refunding_user.id)
      end.to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob).with(@purchase.seller.id)
    end

    context "when partial refund amount is zero" do
      it "does not process a refund" do
        flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 0)
        @purchase.refund_purchase!(flow_of_funds, @refunding_user.id)
        expect(@purchase.errors[:base].first).to eq("The purchase could not be refunded. Please check the refund amount.")
      end
    end

    describe "Low balance related sidekiq jobs" do
      before do
        @flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @purchase.price_cents)
      end

      context "when refunding user is not admin" do
        before do
          @purchase.refund_purchase!(@flow_of_funds, @refunding_user.id)
        end

        it "enqueues LowBalanceFraudCheckWorker" do
          expect(LowBalanceFraudCheckWorker).to have_enqueued_sidekiq_job(@purchase.id)
        end
      end

      context "when refunding user is admin" do
        before do
          admin_user = create(:admin_user)
          @purchase.refund_purchase!(@flow_of_funds, admin_user.id)
        end

        it "doesn't enqueue LowBalanceFraudCheckWorker" do
          expect(LowBalanceFraudCheckWorker).not_to have_enqueued_sidekiq_job(@purchase.id)
        end
      end
    end

    describe "gift purchases" do
      let(:link) { create(:product, price_cents: 200) }
      let(:gift) { create(:gift) }

      before do
        @gifter_purchase = create(:purchase, link:, gift_given: gift, is_gift_sender_purchase: true)
        @giftee_purchase = create(:purchase, link:, gift_received: gift, is_gift_receiver_purchase: true)
      end

      context "when gifter purchase is partially refunded" do
        before do
          flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 100)
          @gifter_purchase.refund_purchase!(flow_of_funds, @gifter_purchase.link.user.id)
        end

        it "sets the stripe_partially_refunded of giftee purchase to true" do
          expect(@giftee_purchase.reload.stripe_partially_refunded).to eq true
        end

        it "doesn't change the stripe_refunded of giftee purchase" do
          expect(@giftee_purchase.reload.stripe_refunded).to be_nil
        end
      end

      context "when gifter purchase is fully refunded" do
        before do
          flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, @gifter_purchase.price_cents)
          @gifter_purchase.refund_purchase!(flow_of_funds, @gifter_purchase.link.user.id)
        end

        it "sets the stripe_refunded of giftee purchase to true" do
          expect(@giftee_purchase.reload.stripe_refunded).to eq true
        end

        it "sets the stripe_partially_refunded of giftee purchase to false" do
          expect(@giftee_purchase.reload.stripe_partially_refunded).to eq false
        end
      end
    end
  end

  describe "#refund_for_fraud!" do
    before do
      @user = create(:user, unpaid_balance_cents: @initial_balance)
      @product = create(:product, user: @user)
      @purchase = create(:purchase_in_progress, link: @product, chargeable: create(:chargeable), purchaser: create(:user))
      @purchase.process!
      @purchase.mark_successful!
      calculated_fingerprint = "3dfakl93klfdjsa09rn"
      allow(Digest::MD5).to receive(:hexdigest).and_return(calculated_fingerprint)
    end

    it "refunds the original purchase" do
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, hash_including(is_for_fraud: true)).and_call_original
      expect(@purchase.stripe_refunded).to_not be(true)
      @purchase.refund_for_fraud!(create(:admin_user).id)
      @purchase.reload
      expect(@purchase.stripe_refunded).to_not be(false)
      expect(@purchase.refunds).to_not be_empty
      expect(@purchase.refunds.first.is_for_fraud).to be(true)
    end

    it "does not retain the processor fee" do
      expect(@purchase.stripe_refunded).to be(false)
      expect(@purchase.charged_using_gumroad_merchant_account?).to be(true)
      expect(ChargeProcessor).to receive(:refund!).with(@purchase.charge_processor_id, @purchase.stripe_transaction_id, hash_including(is_for_fraud: true)).and_call_original

      @purchase.refund_for_fraud!(create(:admin_user).id)

      @purchase.reload
      expect(@purchase.stripe_refunded).to be(true)
      expect(@purchase.is_refund_chargeback_fee_waived).to be(true)
      expect(@purchase.refunds).to_not be_empty
      expect(@purchase.refunds.first.is_for_fraud).to be(true)
      expect(@purchase.refunds.first.retained_fee_cents).to be(nil)
    end

    it "queues an email to the seller informing them of the refund" do
      expect do
        @purchase.refund_for_fraud!(@user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :purchase_refunded_for_fraud).with(@purchase_id)
    end

    describe "subscription purchases" do
      it "cancels the subscription effective immediately" do
        purchase = create(:membership_purchase)

        purchase.refund_for_fraud!(create(:admin_user).id)

        subscription = purchase.subscription
        expect(subscription.cancelled?).to eq true
        expect(subscription.deactivated?).to eq true
      end
    end
  end

  describe "#refund_for_fraud_and_block_buyer!" do
    let(:admin) { create(:admin_user) }
    let(:purchase) { create(:purchase) }

    it "calls refund_for_fraud! and block_buyer!" do
      expect(purchase).to receive(:refund_for_fraud!).with(admin.id)
      expect(purchase).to receive(:block_buyer!).with(blocking_user_id: admin.id)
      purchase.refund_for_fraud_and_block_buyer!(admin.id)
    end
  end

  describe "refund purchase partially from stripe" do
    let(:merchant_account) { nil }

    before do
      @initial_balance = 200
      @user = create(:user)
      merchant_account
      @product = create(:product, user: @user)
      @purchase = create(:purchase_in_progress, link: @product, chargeable: create(:chargeable))
      @purchase.process!
      @purchase.mark_successful!
      @event = create(:event, event_name: "purchase", purchase_id: @purchase.id, link_id: @product.id)
      @balance = if merchant_account
        create(:balance, user: @user, amount_cents: @initial_balance, merchant_account:, holding_currency: Currency::CAD)
      else
        create(:balance, user: @user, amount_cents: @initial_balance)
      end
      @initial_num_paid_download = @product.sales.paid.count
    end

    it "changes stripe_partially_refunded status" do
      expect(@purchase.stripe_partially_refunded).to_not be(true)
      expect(@purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original

      travel_to(Time.zone.local(2023, 11, 27)) do
        @purchase.refund_partial_purchase!(@purchase.price_cents - 10, @user.id)
      end

      expect(@purchase.reload.stripe_partially_refunded).to be(true)
      expect(@purchase.is_refund_chargeback_fee_waived).to be(false)
    end

    it "creates a refund object" do
      expect(@purchase.stripe_partially_refunded).to_not be(true)
      @purchase.refund_partial_purchase!(10, @user.id)
      expect(@purchase.stripe_partially_refunded).to be(true)
      @purchase.reload
      expect(@purchase.amount_refunded_cents).to be(10)
    end

    it "debits the gumroad fee from merchant account" do
      expect(@purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original

      @purchase.refund_partial_purchase!(@purchase.price_cents - 10, @user.id)

      expect(@purchase.reload.stripe_partially_refunded).to be(true)
      expect(@purchase.is_refund_chargeback_fee_waived).to be(false)
    end

    it "handles multiple partial refunds" do
      expect(@purchase.stripe_partially_refunded).to_not be(true)
      @purchase.refund_partial_purchase!(10, @user.id)
      @purchase.refund_partial_purchase!(10, @user.id)
      @purchase.reload
      expect(@purchase.stripe_partially_refunded).to be(true)
      expect(@purchase.amount_refunded_cents).to be(20)
    end

    it "marks fully refunded if subsequent refund exceeds price_cents" do
      expect(@purchase.stripe_partially_refunded).to_not be(true)
      @purchase.refund_partial_purchase!(10, @user.id)
      @purchase.refund_partial_purchase!(@purchase.price_cents - 10, @user.id)
      @purchase.reload
      expect(@purchase.stripe_refunded).to be(true)
      expect(@purchase.stripe_partially_refunded).to be(false)
      expect(@purchase.amount_refunded_cents).to be(@purchase.price_cents)
    end

    it "notifies customer about the refund" do
      expect(@purchase.stripe_partially_refunded).to_not be(true)
      expect(CustomerMailer).to receive(:partial_refund).with(@purchase.email, @purchase.link.id, @purchase.id, 10, "partially").and_call_original
      @purchase.refund_partial_purchase!(10, @user.id)
      @purchase.reload
      expect(@purchase.stripe_partially_refunded).to be(true)
      expect(@purchase.amount_refunded_cents).to be(10)
    end
  end

  describe "refund purchase with 0 fee_cents" do
    let(:merchant_account) { create(:merchant_account_stripe_canada, user: @seller) }

    before do
      @initial_balance = 200
      @seller = create(:user)
      merchant_account
      @product = create(:product, user: @seller)
      allow_any_instance_of(Purchase).to receive(:calculate_fees).and_return(0)
      @no_fee_purchase = create(:purchase_in_progress, link: @product, chargeable: create(:chargeable), fee_cents: 0)
      @no_fee_purchase.process!
      @no_fee_purchase.mark_successful!
      @event = create(:event, event_name: "purchase", purchase_id: @no_fee_purchase.id, link_id: @product.id)
      @balance = if merchant_account
        create(:balance, user: @seller, amount_cents: @initial_balance, merchant_account:, holding_currency: Currency::CAD)
      else
        create(:balance, user: @seller, amount_cents: @initial_balance)
      end
      @initial_num_paid_download = @product.sales.paid.count
      expect(@no_fee_purchase.fee_cents).to eq(0)
    end

    it "creates a balance transaction for the refund" do
      charge_refund = nil
      original_charge_processor_refund = ChargeProcessor.method(:refund!)
      expect(ChargeProcessor).to receive(:refund!) do |*args, **kwargs|
        charge_refund = original_charge_processor_refund.call(*args, **kwargs)
        charge_refund
      end

      travel_to(Time.zone.local(2023, 11, 27)) do
        @no_fee_purchase.refund_and_save!(@seller.id)
      end

      flow_of_funds = charge_refund.flow_of_funds

      balance_transaction = BalanceTransaction.where.not(refund_id: nil).last
      expect(balance_transaction.user).to eq(@seller)
      expect(balance_transaction.merchant_account).to eq(merchant_account)
      expect(balance_transaction.merchant_account).to eq(@no_fee_purchase.merchant_account)
      expect(balance_transaction.refund).to eq(@no_fee_purchase.refunds.last)
      expect(balance_transaction.issued_amount_currency).to eq(Currency::USD)
      expect(balance_transaction.issued_amount_currency).to eq(flow_of_funds.issued_amount.currency)
      expect(balance_transaction.issued_amount_gross_cents).to eq(-1 * @no_fee_purchase.total_transaction_cents)
      expect(balance_transaction.issued_amount_gross_cents).to eq(flow_of_funds.issued_amount.cents)
      expect(balance_transaction.issued_amount_net_cents).to eq(-1 * @no_fee_purchase.payment_cents)
      expect(balance_transaction.holding_amount_currency).to eq(Currency::CAD)
      expect(balance_transaction.holding_amount_currency).to eq(flow_of_funds.merchant_account_gross_amount.currency)
      expect(balance_transaction.holding_amount_currency).to eq(flow_of_funds.merchant_account_net_amount.currency)
      expect(balance_transaction.holding_amount_gross_cents).to eq(flow_of_funds.merchant_account_gross_amount.cents)
      expect(balance_transaction.holding_amount_net_cents).to eq(flow_of_funds.merchant_account_net_amount.cents)
    end

    it "updates the balance of the seller" do
      expect(ChargeProcessor).to receive(:refund!).with(@no_fee_purchase.charge_processor_id, @no_fee_purchase.stripe_transaction_id, anything).and_call_original

      travel_to(Time.zone.local(2023, 11, 27)) do
        @no_fee_purchase.refund_and_save!(@seller.id)
      end

      verify_balance(@seller.reload, @initial_balance - @no_fee_purchase.price_cents - @no_fee_purchase.processor_fee_cents)
      expect(@no_fee_purchase.purchase_refund_balance).to eq @balance
      expect(@no_fee_purchase.stripe_refunded).to be(true)
      expect(@product.sales.paid.count).to eq(@initial_num_paid_download - 1)
    end
  end

  describe "refund purchase with affiliate_credit" do
    let!(:merchant_account) { nil }
    let(:initial_balance) { 200 }
    let(:product) { create(:product, price_cents: 10_00) }
    let(:seller) { product.user }
    let(:affiliate_user) { create(:affiliate_user) }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1000, products: [product]) }
    let(:purchase) { create(:purchase_in_progress, link: product, seller:, affiliate:, chargeable: create(:chargeable)) }

    before do
      purchase.process!
      purchase.update_balance_and_mark_successful!
    end

    it "updates balance of affiliate user as well as seller", :vcr do
      purchase.refund_and_save!(create(:admin_user).id)
      seller.reload
      affiliate_user.reload
      verify_balance(affiliate_user, 0)
      verify_balance(seller, -(purchase.price_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + Purchase::PROCESSOR_FIXED_FEE_CENTS).round)
      affiliate_balance, balance = Balance.last(2)
      expect(purchase.purchase_refund_balance).to eq balance
      expect(purchase.affiliate_credit.affiliate_credit_refund_balance).to eq affiliate_balance
      expect(purchase.affiliate).to eq affiliate
      expect(purchase.affiliate_credit.affiliate).to eq affiliate
      expect(affiliate_user.balances.count).to eq 1
      expect(affiliate_user.balances.last.amount_cents).to eq 0
      expect(affiliate_user.balances.last.state).to eq "unpaid"
      expect(seller.balances.count).to eq 1
      expect(seller.balances.last.amount_cents).to eq(-(purchase.price_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + Purchase::PROCESSOR_FIXED_FEE_CENTS).round)
      expect(seller.balances.last.state).to eq "unpaid"
    end

    it "creates two balance transactions for the refund" do
      charge_refund = nil
      original_charge_processor_refund = ChargeProcessor.method(:refund!)
      expect(ChargeProcessor).to receive(:refund!) do |*args, **kwargs|
        charge_refund = original_charge_processor_refund.call(*args, **kwargs)
        charge_refund
      end
      expect(purchase).to receive(:debit_processor_fee_from_merchant_account!)

      purchase.refund_and_save!(create(:admin_user).id)
      flow_of_funds = charge_refund.flow_of_funds

      balance_transaction_1 = BalanceTransaction.where(user_id: affiliate_user.id).last
      balance_transaction_2 = BalanceTransaction.where(user_id: seller.id).where.not(refund_id: nil).last

      expect(balance_transaction_1.user).to eq(affiliate_user)
      expect(balance_transaction_1.merchant_account).to eq(purchase.affiliate_merchant_account)
      expect(balance_transaction_1.refund).to eq(purchase.refunds.last)
      expect(balance_transaction_1.issued_amount_currency).to eq(Currency::USD)
      expect(balance_transaction_1.issued_amount_gross_cents).to eq(-1 * purchase.affiliate_credit_cents)
      expect(balance_transaction_1.issued_amount_net_cents).to eq(-1 * purchase.affiliate_credit_cents)
      expect(balance_transaction_1.holding_amount_currency).to eq(Currency::USD)
      expect(balance_transaction_1.holding_amount_gross_cents).to eq(-1 * purchase.affiliate_credit_cents)
      expect(balance_transaction_1.holding_amount_net_cents).to eq(-1 * purchase.affiliate_credit_cents)

      expect(balance_transaction_2.user).to eq(seller)
      expect(balance_transaction_2.merchant_account).to eq(purchase.merchant_account)
      expect(balance_transaction_2.refund).to eq(purchase.refunds.last)
      expect(balance_transaction_2.issued_amount_currency).to eq(Currency::USD)
      expect(balance_transaction_2.issued_amount_currency).to eq(flow_of_funds.issued_amount.currency)
      expect(balance_transaction_2.issued_amount_gross_cents).to eq(-1 * purchase.total_transaction_cents)
      expect(balance_transaction_2.issued_amount_gross_cents).to eq(flow_of_funds.issued_amount.cents)
      expect(balance_transaction_2.issued_amount_net_cents).to eq(-1 * (purchase.payment_cents - purchase.affiliate_credit_cents))
      expect(balance_transaction_2.holding_amount_currency).to eq(Currency::USD)
      expect(balance_transaction_2.holding_amount_currency).to eq(flow_of_funds.settled_amount.currency)
      expect(balance_transaction_2.holding_amount_currency).to eq(flow_of_funds.gumroad_amount.currency)
      expect(balance_transaction_2.holding_amount_gross_cents).to eq(-1 * purchase.total_transaction_cents)
      expect(balance_transaction_2.holding_amount_gross_cents).to eq(flow_of_funds.settled_amount.cents)
      expect(balance_transaction_2.holding_amount_gross_cents).to eq(flow_of_funds.gumroad_amount.cents)
      expect(balance_transaction_2.holding_amount_net_cents).to eq(-1 * (purchase.payment_cents - purchase.affiliate_credit_cents))
    end

    context "when the affiliate paid part of the Gumroad fees" do
      let(:affiliate) { create(:collaborator, affiliate_user:, seller:, affiliate_basis_points: 5000, products: [product]) }

      it "refunds the full affiliate credit (net of fees)" do
        purchase.refund_and_save!(create(:admin_user).id)
        verify_balance(affiliate_user.reload, 0)
      end
    end

    describe "partially" do
      it "updates balance of affiliate user as well as seller" do
        expect(purchase).to receive(:debit_processor_fee_from_merchant_account!).and_call_original

        seller_balance = seller.unpaid_balance_cents
        purchase.refund_and_save!(create(:admin_user).id, amount_cents: 600)
        seller.reload
        affiliate_user.reload
        # affiliate_basis_points: 1000, on 1000 cents, 600 cents refunded => 100 - 60% of 100 = 100 - 60 = 40
        verify_balance(affiliate_user, 31)
        verify_balance(seller, seller_balance - 450) # - 600 (refunded amount) + 150 (returned gumroad fee)
        affiliate_balance, balance = Balance.last(2)
        expect(purchase.purchase_refund_balance).to eq balance
        expect(purchase.affiliate_credit.affiliate_credit_refund_balance).to eq affiliate_balance
        expect(purchase.affiliate).to eq affiliate
        expect(purchase.affiliate_credit.affiliate).to eq affiliate
        expect(affiliate_user.balances.count).to eq 1
        expect(affiliate_user.balances.last.amount_cents).to eq 31
        expect(affiliate_user.balances.last.state).to eq "unpaid"
        expect(seller.balances.count).to eq 1
        expect(seller.balances.last.amount_cents).to eq(262)
        expect(seller.balances.last.state).to eq "unpaid"
      end

      it "creates affiliate_partial_refunds and balances" do
        seller_balance = seller.unpaid_balance_cents
        purchase.refund_and_save!(seller.id, amount_cents: 600)
        seller.reload
        affiliate_user.reload
        # affiliate_basis_points: 1000, on 1000 cents, 600 cents refunded => 100 - 60% of 100 = 100 - 60 = 40
        affiliate_partial_refund = affiliate_user.affiliate_partial_refunds.first
        # 60% of 100
        expect(affiliate_partial_refund.amount_cents).to eq 48
        expect(affiliate_partial_refund.total_credit_cents).to eq 79
        expect(affiliate_partial_refund.purchase).to eq purchase

        verify_balance(affiliate_user, 31)
        verify_balance(seller, seller_balance - 450) # - 600 (refunded amount) + 150 (returned gumroad fee)
        affiliate_balance, balance = Balance.last(2)
        expect(purchase.purchase_refund_balance).to eq balance
        expect(purchase.affiliate_credit.affiliate_credit_refund_balance).to eq affiliate_balance
        expect(purchase.affiliate).to eq affiliate
        expect(purchase.affiliate_credit.affiliate).to eq affiliate
        expect(affiliate_user.balances.count).to eq 1
        expect(affiliate_user.balances.last.amount_cents).to eq(affiliate_partial_refund.total_credit_cents - affiliate_partial_refund.amount_cents)
        expect(affiliate_user.balances.last.state).to eq "unpaid"
        expect(seller.balances.count).to eq 1
        expect(seller.balances.last.amount_cents).to eq(seller_balance - 450) # - 600 (refunded amount) + 150 (returned gumroad fee)
        expect(seller.balances.last.state).to eq "unpaid"
      end

      it "cents calculation for balances tally up with affiliate_partial_refund" do
        seller_balance = seller.unpaid_balance_cents
        purchase.refund_and_save!(seller.id, amount_cents: 400)
        seller.reload
        affiliate_user.reload
        # affiliate_basis_points: 1000, on 1000 cents, 400 cents refunded => 100 - 40% of 100 = 100 - 40 = 60
        affiliate_partial_refund = affiliate_user.affiliate_partial_refunds.first
        # 40% of 100
        expect(affiliate_partial_refund.amount_cents).to eq 32
        expect(affiliate_partial_refund.total_credit_cents).to eq 79
        expect(affiliate_partial_refund.purchase).to eq purchase

        verify_balance(affiliate_user, (affiliate_partial_refund.total_credit_cents - affiliate_partial_refund.amount_cents))
        last_refund = purchase.refunds.last
        seller_balance_deduction = (last_refund.amount_cents - affiliate_partial_refund.amount_cents - last_refund.fee_cents - affiliate_partial_refund.fee_cents + last_refund.retained_fee_cents)
        verify_balance(seller, seller_balance - seller_balance_deduction)
      end

      it "processes partial and then full refund" do
        purchase.refund_and_save!(seller.id, amount_cents: 400)
        seller.reload
        affiliate_user.reload

        purchase.refund_and_save!(create(:admin_user).id)

        # affiliate_partial_refunds total sum should tally up to actual credits
        expect(affiliate_user.affiliate_partial_refunds.sum(:amount_cents)).to eq(80)

        verify_balance(affiliate_user, -1)
        verify_balance(seller, -(purchase.price_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + Purchase::PROCESSOR_FIXED_FEE_CENTS).round + 21)
        affiliate_balance, balance = Balance.last(2)
        expect(purchase.purchase_refund_balance).to eq balance
        expect(purchase.affiliate_credit.affiliate_credit_refund_balance).to eq affiliate_balance
        expect(purchase.affiliate).to eq affiliate
        expect(purchase.affiliate_credit.affiliate).to eq affiliate
        expect(affiliate_user.balances.count).to eq 1
        expect(affiliate_user.balances.last.amount_cents).to eq(-1)
        expect(affiliate_user.balances.last.state).to eq "unpaid"
        expect(seller.balances.count).to eq 1
        expect(seller.balances.last.amount_cents).to eq(-(purchase.price_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + Purchase::PROCESSOR_FIXED_FEE_CENTS).round + 21)
        expect(seller.balances.last.state).to eq "unpaid"
      end

      context "when the affiliate paid part of the Gumroad fees" do
        let(:affiliate) { create(:collaborator, affiliate_user:, seller:, affiliate_basis_points: 5000, products: [product]) }

        it "refunds part of the fees" do
          seller_balance = seller.unpaid_balance_cents

          purchase.refund_and_save!(create(:admin_user).id, amount_cents: 400)
          seller.reload
          affiliate_user.reload

          # Initial purchase:
          # - earned 50% of total price as gross: 50% * $10 = $5
          # - deduct 50% of fees: 50% * $2.09 =  $1.05
          # - net earnings of: $5 - $1.03 = $3.95
          expect(purchase.affiliate_credit_cents).to eq 395
          expect(purchase.affiliate_credit.amount_cents).to eq 395
          expect(purchase.affiliate_credit.fee_cents).to eq 105

          # For a 40% refund, affiliate will be refunded
          # - 40% of their affiliate credit: 40% * $3.97 = $1.59
          # - 40% of the fees they paid: 40% * $1.03 = $0.41
          # - total refund: 40% * $5 = $2
          affiliate_partial_refund = affiliate_user.affiliate_partial_refunds.first
          expect(affiliate_partial_refund.amount_cents).to eq 159
          expect(affiliate_partial_refund.fee_cents).to eq 41
          expect(affiliate_partial_refund.total_credit_cents).to eq 395
          expect(affiliate_partial_refund.purchase).to eq purchase

          new_balance = affiliate_partial_refund.total_credit_cents - affiliate_partial_refund.amount_cents # $3.95 - $1.59 = $2.36 (we don't deduct fees because the balance is actually net of fees)
          verify_balance(affiliate_user, new_balance)
          last_refund = purchase.refunds.last
          seller_balance_deduction = (last_refund.amount_cents - affiliate_partial_refund.amount_cents - affiliate_partial_refund.fee_cents - last_refund.fee_cents + last_refund.retained_fee_cents)
          verify_balance(seller, seller_balance - seller_balance_deduction)
        end
      end

      context "when the affiliate cut has changed since the purchase was made" do
        it "uses the cut at the time of the purchase when determining how much to refund" do
          affiliate.update!(affiliate_basis_points: affiliate.affiliate_basis_points + 1000)

          seller_balance = seller.unpaid_balance_cents

          purchase.refund_and_save!(seller.id, amount_cents: 600)

          seller.reload
          affiliate_user.reload
          # affiliate_basis_points: 1000, on 1000 cents, 600 cents refunded => 100 - 60% of 100 = 100 - 60 = 40
          affiliate_partial_refund = affiliate_user.affiliate_partial_refunds.first
          # 60% of 10
          expect(affiliate_partial_refund.amount_cents).to eq 48
          expect(affiliate_partial_refund.total_credit_cents).to eq 79
          expect(affiliate_partial_refund.purchase).to eq purchase

          verify_balance(affiliate_user, 31)
          verify_balance(seller, seller_balance - 450) # - 600 (refunded amount) + 150 (returned gumroad fee)
        end
      end
    end

    describe "user has a merchant account" do
      let!(:merchant_account) { create(:merchant_account_stripe_canada, user: seller) }

      it "updates balance of affiliate user as well as seller" do
        travel_to(Time.zone.local(2023, 10, 6)) do
          purchase.refund_and_save!(create(:admin_user).id)
        end
        seller.reload
        affiliate_user.reload
        verify_balance(affiliate_user, 0)
        verify_balance(seller, -(purchase.price_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + Purchase::PROCESSOR_FIXED_FEE_CENTS).round)
        affiliate_balance, balance = Balance.last(2)
        expect(purchase.purchase_refund_balance).to eq balance
        expect(purchase.affiliate_credit.affiliate_credit_refund_balance).to eq affiliate_balance
        expect(purchase.affiliate).to eq affiliate
        expect(purchase.affiliate_credit.affiliate).to eq affiliate
        expect(affiliate_user.balances.count).to eq 1
        expect(affiliate_user.balances.last.amount_cents).to eq 0
        expect(affiliate_user.balances.last.state).to eq "unpaid"
        expect(seller.balances.count).to eq 1
        expect(seller.balances.last.amount_cents).to eq(-(purchase.price_cents * Purchase::PROCESSOR_FEE_PER_THOUSAND / 1000.0 + Purchase::PROCESSOR_FIXED_FEE_CENTS).round)
        expect(seller.balances.last.state).to eq "unpaid"
      end

      it "creates two balance transactions for the refund" do
        charge_refund = nil
        original_charge_processor_refund = ChargeProcessor.method(:refund!)
        expect(ChargeProcessor).to receive(:refund!) do |*args, **kwargs|
          charge_refund = original_charge_processor_refund.call(*args, **kwargs)
          charge_refund
        end

        travel_to(Time.zone.local(2023, 10, 6)) do
          purchase.refund_and_save!(create(:admin_user).id)
        end
        flow_of_funds = charge_refund.flow_of_funds

        balance_transaction_1 = BalanceTransaction.where(user_id: affiliate_user.id).last
        balance_transaction_2 = BalanceTransaction.where(user_id: seller.id).where.not(refund_id: nil).last

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
        expect(balance_transaction_2.issued_amount_currency).to eq(flow_of_funds.issued_amount.currency)
        expect(balance_transaction_2.issued_amount_gross_cents).to eq(-1 * purchase.total_transaction_cents)
        expect(balance_transaction_2.issued_amount_gross_cents).to eq(flow_of_funds.issued_amount.cents)
        expect(balance_transaction_2.issued_amount_net_cents).to eq(-1 * (purchase.payment_cents - purchase.affiliate_credit_cents))
        expect(balance_transaction_2.holding_amount_currency).to eq(Currency::CAD)
        expect(balance_transaction_2.holding_amount_currency).to eq(flow_of_funds.merchant_account_gross_amount.currency)
        expect(balance_transaction_2.holding_amount_currency).to eq(flow_of_funds.merchant_account_net_amount.currency)
        expect(balance_transaction_2.holding_amount_gross_cents).to eq(flow_of_funds.merchant_account_gross_amount.cents)
        expect(balance_transaction_2.holding_amount_net_cents).to eq(flow_of_funds.merchant_account_net_amount.cents)
      end
    end
  end

  describe "refund purchase with affiliate_credit with merchant_migration enabled" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:affiliate_user) { create(:affiliate_user) }
    let(:affiliate_merchant_account) { create(:merchant_account_stripe, user: affiliate_user) }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1500, products: [product]) }
    let!(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
    let(:purchase) { create(:purchase_in_progress, link: product, seller:, affiliate:, chargeable: create(:chargeable, product_permalink: product.unique_permalink)) }

    before do
      Feature.activate_user(:merchant_migration, seller)
      create(:user_compliance_info, user: seller)
      purchase.process!
      purchase.update_balance_and_mark_successful!
    end

    describe "user has no merchant account" do
      it "does not update balance of affiliate user or seller" do
        merchant_account.mark_deleted!

        verify_balance(affiliate_user, 6)
        verify_balance(seller, 0)

        purchase.reload.refund_and_save!(seller.id)
        seller.reload
        affiliate_user.reload

        verify_balance(affiliate_user, 6)
        verify_balance(seller, 0)
        expect(purchase.errors[:base].first).to eq("We cannot refund this sale because you have disconnected the associated payment account on Stripe. Please connect it and try again.")
      end
    end

    describe "user has a merchant account" do
      it "updates balance of affiliate user but not the seller" do
        expect(Stripe::Refund).to receive(:create).with({
                                                          charge: purchase.stripe_transaction_id,
                                                          refund_application_fee: false
                                                        },
                                                        {
                                                          stripe_account: merchant_account.charge_processor_merchant_id
                                                        }).and_call_original

        purchase.refund_and_save!(seller.id)
        seller.reload
        affiliate_user.reload

        verify_balance(affiliate_user, 0)
        verify_balance(seller, 0)
        affiliate_balance = Balance.last
        expect(purchase.reload.purchase_refund_balance).to eq nil
        expect(purchase.affiliate_credit.affiliate_credit_refund_balance).to eq affiliate_balance
        expect(purchase.affiliate).to eq affiliate
        expect(purchase.affiliate_credit.affiliate).to eq affiliate
        expect(affiliate_user.balances.count).to eq 1
        expect(seller.balances.count).to eq 0
      end

      it "creates a balance transaction for the affiliate user" do
        original_charge_processor_refund = ChargeProcessor.method(:refund!)
        expect(ChargeProcessor).to receive(:refund!) do |*args, **kwargs|
          charge_refund = original_charge_processor_refund.call(*args, **kwargs)
          charge_refund
        end

        purchase.refund_and_save!(seller.id)

        balance_transaction_1 = BalanceTransaction.where.not(refund_id: nil).last

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
      end
    end
  end

  describe "#reverse_the_transfer_made_for_dispute_win!" do
    it "does nothing and returns if holder of funds is not Stripe" do
      purchase = create(:purchase, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
      create(:dispute, purchase:, state: "won", won_at: Time.at(1669749973).utc)
      expect(Stripe::Transfer).to_not receive(:list)

      purchase.send(:reverse_the_transfer_made_for_dispute_win!)
    end

    it "does nothing and returns if purchase is not disputed" do
      merchant_account = create(:merchant_account, charge_processor_merchant_id: "acct_1MABWa2noRrbY6cK")
      purchase = create(:purchase, link: create(:product, user: merchant_account.user), merchant_account:)
      expect(Stripe::Transfer).to_not receive(:list)

      purchase.send(:reverse_the_transfer_made_for_dispute_win!)
    end

    it "does nothing and returns if purchase dispute is not won" do
      merchant_account = create(:merchant_account, charge_processor_merchant_id: "acct_1MABWa2noRrbY6cK")
      purchase = create(:purchase, link: create(:product, user: merchant_account.user), merchant_account:)
      create(:dispute, purchase:, state: "lost", lost_at: Time.at(1669749973).utc)
      expect(Stripe::Transfer).to_not receive(:list)

      purchase.send(:reverse_the_transfer_made_for_dispute_win!)
    end

    it "tries to reverse the dispute transfer if purchase dispute is won and holder of funds is Stripe" do
      merchant_account = create(:merchant_account, charge_processor_merchant_id: "acct_1MABWa2noRrbY6cK")
      purchase = create(:purchase, link: create(:product, user: merchant_account.user), merchant_account:)
      create(:dispute, purchase:, state: "won", won_at: Time.at(1669749973).utc)
      expect(Stripe::Transfer).to receive(:list).and_call_original

      purchase.send(:reverse_the_transfer_made_for_dispute_win!)
    end
  end
end
