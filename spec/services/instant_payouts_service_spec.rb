# frozen_string_literal: true

require "spec_helper"

describe InstantPayoutsService, :vcr do
  let(:seller) { create(:user) }

  before do
    create(:tos_agreement, user: seller)
    create(:user_compliance_info, user: seller)
    create_list(:payment_completed, 4, user: seller)
  end

  describe "#perform" do
    context "with stripe account" do
      before do
        create(:ach_account_stripe_succeed, user: seller)
        merchant_account = StripeMerchantAccountManager.create_account(seller.reload, passphrase: "1234")
        @merchant_account = merchant_account

        @stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
        @stripe_account.refresh until @stripe_account.payouts_enabled?
      end

      context "when seller has a balance within the instant payout range" do
        before do
          Stripe::Transfer.create(destination: @stripe_account.id, currency: "usd", amount: 1000_00)
          create(:balance, amount_cents: 1000_00, holding_amount_cents: 1000_00, user: seller, date: Date.yesterday, merchant_account: @merchant_account)
        end

        it "creates and processes an instant payout" do
          expect do
            result = described_class.new(seller).perform
            expect(result[:success]).to be true
          end.to change { Payment.count }.by(1)

          payment = Payment.last
          expect(payment.payout_type).to eq(Payouts::PAYOUT_TYPE_INSTANT)
          expect(payment.processor).to eq(PayoutProcessorType::STRIPE)
          expect(payment.user_id).to eq(seller.id)
          expect(payment.state).to eq("processing")
          expect(payment.stripe_transfer_id).to match(/po_/)
          expect(payment.stripe_connect_account_id).to match(/acct_/)
        end
      end

      context "when the seller has balances that exceed the maximum instant payout amount" do
        let!(:balance1) { create(:balance, amount_cents: 6000_00, holding_amount_cents: 6000_00, user: seller, date: 7.days.ago, merchant_account: @merchant_account) }
        let!(:balance2) { create(:balance, amount_cents: 3999_00, holding_amount_cents: 3999_00, user: seller, date: 6.days.ago, merchant_account: @merchant_account) }

        let!(:balance3) { create(:balance, amount_cents: 5100_00, holding_amount_cents: 5100_00, user: seller, date: 5.days.ago, merchant_account: @merchant_account) }

        let!(:balance4) { create(:balance, amount_cents: 5000_00, holding_amount_cents: 5000_00, user: seller, date: 4.days.ago, merchant_account: @merchant_account) }
        let!(:balance5) { create(:balance, amount_cents: 3500_00, holding_amount_cents: 3500_00, user: seller, date: 3.days.ago, merchant_account: @merchant_account) }

        let!(:balance6) { create(:balance, amount_cents: 3000_00, holding_amount_cents: 3000_00, user: seller, date: 2.days.ago, merchant_account: @merchant_account) }
        let!(:balance7) { create(:balance, amount_cents: 3000_00, holding_amount_cents: 3000_00, user: seller, date: 1.day.ago, merchant_account: @merchant_account) }

        before do
          Stripe::Transfer.create(destination: @stripe_account.id, currency: "usd", amount: 29_599_00)
        end

        it "creates and processes multiple instant payouts" do
          expect do
            result = described_class.new(seller).perform
            expect(result[:success]).to be true
          end.to change { Payment.count }.by(4)

          payments = Payment.last(4)

          expect(payments[0].amount_cents).to eq(9_707_76)
          expect(payments[0].balances).to match_array([balance1, balance2])

          expect(payments[1].amount_cents).to eq(4_951_45)
          expect(payments[1].balances).to match_array([balance3])

          expect(payments[2].amount_cents).to eq(8_252_42)
          expect(payments[2].balances).to match_array([balance4, balance5])

          expect(payments[3].amount_cents).to eq(5_825_24)
          expect(payments[3].balances).to match_array([balance6, balance7])

          payments.each do |payment|
            expect(payment.payout_type).to eq(Payouts::PAYOUT_TYPE_INSTANT)
            expect(payment.processor).to eq(PayoutProcessorType::STRIPE)
            expect(payment.user_id).to eq(seller.id)
            expect(payment.state).to eq("processing")
            expect(payment.stripe_transfer_id).to match(/po_/)
            expect(payment.stripe_connect_account_id).to match(/acct_/)
          end
        end
      end

      context "when seller has a balance less than $10" do
        before do
          create(:balance, amount_cents: 500, holding_amount_cents: 500, user: seller, date: Date.yesterday, merchant_account: @merchant_account)
          Stripe::Transfer.create(destination: @stripe_account.id, currency: "usd", amount: 5_00)
        end

        it "returns error message" do
          expect do
            result = described_class.new(seller).perform
            expect(result).to eq(
              success: false,
              error: "You need at least $10 in your balance to request an instant payout."
            )
          end.not_to change { Payment.count }
        end
      end

      context "when seller has a balance greater than $10,000" do
        before do
          create(:balance, amount_cents: 11_000_00, holding_amount_cents: 11_000_00, user: seller, date: Date.yesterday, merchant_account: @merchant_account)
          Stripe::Transfer.create(destination: @stripe_account.id, currency: "usd", amount: 11_000_00)
        end

        it "returns error message" do
          expect do
            result = described_class.new(seller).perform
            expect(result).to eq(
              success: false,
              error: "Your balance exceeds the maximum instant payout amount. Please contact support for assistance."
            )
          end.not_to change { Payment.count }
        end
      end
    end

    context "when seller is not eligible for instant payouts" do
      before do
        allow(seller).to receive(:eligible_for_instant_payouts?).and_return(false)
      end

      it "returns error message" do
        expect do
          result = described_class.new(seller).perform
          expect(result).to eq(
            success: false,
            error: "Your account is not eligible for instant payouts at this time."
          )
        end.not_to change { Payment.count }
      end
    end

    context "when seller has no stripe account" do
      it "returns an error" do
        expect do
          result = described_class.new(seller).perform
          expect(result).to eq(
            success: false,
            error: "Your account is not eligible for instant payouts at this time."
          )
        end.not_to change { Payment.count }
      end
    end

    context "when the payout fails" do
      let(:payment) { build(:payment_failed) }

      before do
        allow_any_instance_of(User).to receive(:eligible_for_instant_payouts?).and_return(true)
        allow_any_instance_of(User).to receive(:instantly_payable_amount_cents_on_stripe).and_return(1000_00)
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
        create(:balance, holding_amount_cents: 1000_00, user: seller, date: Date.yesterday)
        allow(Payouts).to receive(:create_payment).and_return([payment, []])
        allow(StripePayoutProcessor).to receive(:process_payments)
      end

      it "returns an error" do
        result = described_class.new(seller).perform
        expect(result).to eq(success: false, error: "Failed to process instant payout")
      end
    end
  end
end
