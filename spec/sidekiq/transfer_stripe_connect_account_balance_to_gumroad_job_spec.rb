# frozen_string_literal: true

describe TransferStripeConnectAccountBalanceToGumroadJob do
  describe "#perform", :vcr do
    describe "when merchant account is a creator's Gumroad-controlled Stripe account" do
      describe "when the merchant account is from US" do
        before do
          @merchant_account = create(:merchant_account, country: "US")
          stripe_object_available_double = double(currency: "usd", amount: 900)
          stripe_object_pending_double = double(currency: "usd", amount: 600)
          @stripe_balance = double(available: [stripe_object_available_double], pending: [stripe_object_pending_double])
        end

        it "creates a debit transfer for the amount" do
          transfer = double(id: "tr_123")
          expect(Stripe::Transfer).to receive(:create).with(hash_including({ amount: 1000, currency: "usd" }), hash_including({ stripe_account: @merchant_account.charge_processor_merchant_id })).and_return(transfer)

          described_class.new.perform(@merchant_account.id, 10_00)
        end
      end

      describe "when the merchant account is non-US" do
        before do
          $currency_namespace = Redis::Namespace.new(:currencies, redis: $redis)
          $currency_namespace.set("CAD", 1.33)

          @merchant_account = create(:merchant_account, country: "CA", currency: "cad")
          stripe_object_available_double = double(currency: "cad", amount: 1000)
          stripe_object_pending_double = double(currency: "cad", amount: 995)
          @stripe_balance = double(available: [stripe_object_available_double], pending: [stripe_object_pending_double])
        end

        it "creates a reversal from a single past internal transfer" do
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_123")

          transfer = double(id: "tr_123", amount: 1330, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_123").and_return(transfer)

          transfer_reversal = double(id: "tr_456")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 10_00 })).and_return(transfer_reversal)

          described_class.new.perform(@merchant_account.id, 10_00)
        end

        it "creates reversals for multiple past internal transfers" do
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_123", created_at: 2.days.ago)
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_456", created_at: 1.days.ago)

          transfer = double(id: "tr_123", amount: 1000, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_123").ordered.and_return(transfer)
          transfer_reversal = double(id: "tr_567")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 1000 })).ordered.and_return(transfer_reversal)

          transfer_2 = double(id: "tr_456", amount: 500, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_456").ordered.and_return(transfer_2)
          transfer_reversal_2 = double(id: "tr_890")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_456", hash_including({ amount: 400 })).ordered.and_return(transfer_reversal_2)

          described_class.new.perform(@merchant_account.id, 14_00)
        end

        it "creates reversals for multiple transfers associated with old purchases" do
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)

          transfer = double(id: "tr_123", amount: 1000, amount_reversed: 0, currency: "usd")
          transfer_reversal = double(id: "tr_567")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 999 })).ordered.and_return(transfer_reversal)

          transfer_2 = double(id: "tr_456", amount: 400, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).and_return([transfer, transfer_2])
          transfer_reversal_2 = double(id: "tr_890")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_456", hash_including({ amount: 331 })).ordered.and_return(transfer_reversal_2)

          described_class.new.perform(@merchant_account.id, 1330)
        end

        it "creates reversals for both past internal transfers and transfers associated with old purchases" do
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: nil)
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_123")
          create(:payment_completed, user: @merchant_account.user,
                                     stripe_connect_account_id: @merchant_account.charge_processor_merchant_id,
                                     stripe_internal_transfer_id: "tr_456")

          transfer = double(id: "tr_123", amount: 300, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_123").ordered.and_return(transfer)
          transfer_reversal = double(id: "tr_345")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_123", hash_including({ amount: 300 })).ordered.and_return(transfer_reversal)

          transfer_2 = double(id: "tr_456", amount: 400, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:retrieve).with("tr_456").ordered.and_return(transfer_2)
          transfer_reversal_2 = double(id: "tr_678")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_456", hash_including({ amount: 400 })).ordered.and_return(transfer_reversal_2)

          transfer_3 = double(id: "tr_789", amount: 450, amount_reversed: 0, currency: "usd")
          transfer_4 = double(id: "tr_012", amount: 250, amount_reversed: 0, currency: "usd")
          expect(Stripe::Transfer).to receive(:list).with(hash_including({ destination: @merchant_account.charge_processor_merchant_id })).and_return([transfer_3, transfer_4])
          transfer_reversal_3 = double(id: "tr_901")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_789", hash_including({ amount: 449 })).ordered.and_return(transfer_reversal_3)
          transfer_reversal_4 = double(id: "tr_234")
          expect(Stripe::Transfer).to receive(:create_reversal).with("tr_012", hash_including({ amount: 181 })).ordered.and_return(transfer_reversal_4)

          described_class.new.perform(@merchant_account.id, 1330)
        end
      end
    end
  end
end
