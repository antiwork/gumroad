# frozen_string_literal: true

require "spec_helper"

describe Admin::PaymentPresenter do
  describe "#props" do
    let(:payment) { create(:payment, *payment_traits) }
    let(:payment_traits) { [] }
    let(:presenter) { described_class.new(payment:) }

    subject(:props) { presenter.props }

    describe "basic structure" do
      it "returns a hash with all expected keys" do
        expect(props).to include(
          :external_id,
          :displayed_amount,
          :payout_period_end_date,
          :created_at,
          :user,
          :state,
          :humanized_failure_reason,
          :failed,
          :cancelled,
          :returned,
          :processing,
          :unclaimed,
          :non_terminal_state,
          :processor,
          :is_stripe_processor,
          :is_paypal_processor,
          :processor_fee_cents,
          :stripe_transfer_id,
          :stripe_transfer_url,
          :stripe_connected_account_url,
          :stripe_connect_account_id,
          :bank_account,
          :txn_id,
          :payment_address,
          :correlation_id,
          :was_created_in_split_mode,
          :split_payments_info
        )
      end
    end

    describe "fields" do
      it "returns the correct field values" do
        expect(props[:external_id]).to eq(payment.external_id)
        expect(props[:displayed_amount]).to eq(payment.displayed_amount)
        expect(props[:payout_period_end_date]).to eq(payment.payout_period_end_date)
        expect(props[:created_at]).to eq(payment.created_at)

        expect(props[:state]).to eq(payment.state)
        expect(props[:humanized_failure_reason]).to eq(payment.humanized_failure_reason)
        expect(props[:failed]).to eq(payment.failed?)
        expect(props[:cancelled]).to eq(payment.cancelled?)
        expect(props[:returned]).to eq(payment.returned?)
        expect(props[:processing]).to eq(payment.processing?)
        expect(props[:unclaimed]).to eq(payment.unclaimed?)

        expect(props[:processor]).to eq(payment.processor)
        expect(props[:processor_fee_cents]).to eq(payment.processor_fee_cents)

        expect(props[:txn_id]).to eq(payment.txn_id)
        expect(props[:payment_address]).to eq(payment.payment_address)
        expect(props[:correlation_id]).to eq(payment.correlation_id)

        expect(props[:stripe_transfer_id]).to eq(payment.stripe_transfer_id)
        expect(props[:stripe_connect_account_id]).to eq(payment.stripe_connect_account_id)

        expect(props[:was_created_in_split_mode]).to eq(payment.was_created_in_split_mode)
        expect(props[:split_payments_info]).to eq(payment.split_payments_info)
      end
    end

    describe "user association" do
      context "when payment has a user" do
        let(:user) { create(:user, name: "Test User") }
        let(:payment) { create(:payment, user:) }

        it "returns user information" do
          expect(props[:user]).to eq(
            external_id: user.external_id,
            name: user.name
          )
        end
      end

      context "when payment has no user" do
        let(:payment) { create(:payment, user: nil) }

        it "returns nil" do
          expect(props[:user]).to be_nil
        end
      end
    end

    describe "state predicates" do
      context "when payment is in processing state" do
        let(:payment_traits) { [] } # Default is processing

        it "returns correct state predicates" do
          expect(props[:processing]).to be true
          expect(props[:failed]).to be false
          expect(props[:cancelled]).to be false
          expect(props[:returned]).to be false
          expect(props[:unclaimed]).to be false
        end

        it "identifies non-terminal state correctly" do
          expect(props[:non_terminal_state]).to be true
        end
      end

      context "when payment is failed" do
        let(:payment) { create(:payment_failed) }

        it "returns correct state predicates" do
          expect(props[:failed]).to be true
          expect(props[:processing]).to be false
        end

        it "identifies terminal state correctly" do
          expect(props[:non_terminal_state]).to be false
        end
      end

      context "when payment is cancelled" do
        let(:payment) { create(:payment, state: Payment::CANCELLED) }

        it "returns correct state predicates" do
          expect(props[:cancelled]).to be true
          expect(props[:processing]).to be false
        end
      end

      context "when payment is returned" do
        let(:payment) { create(:payment_returned) }

        it "returns correct state predicates" do
          expect(props[:returned]).to be true
          expect(props[:processing]).to be false
        end
      end

      context "when payment is unclaimed" do
        let(:payment) { create(:payment_unclaimed) }

        it "returns correct state predicates" do
          expect(props[:unclaimed]).to be true
          expect(props[:processing]).to be false
        end

        it "identifies non-terminal state correctly" do
          expect(props[:non_terminal_state]).to be true
        end
      end

      context "when payment is completed" do
        let(:payment) { create(:payment_completed) }

        it "identifies non-terminal state correctly" do
          expect(props[:non_terminal_state]).to be true
        end
      end
    end

    describe "processor types" do
      context "when payment uses PayPal processor" do
        let(:payment) do
          create(:payment_completed,
                 processor: PayoutProcessorType::PAYPAL,
                 txn_id: "PAYPAL-TXN-123",
                 payment_address: "seller@example.com",
                 correlation_id: "CORR-123")
        end

        it "includes PayPal-specific information" do
          expect(props[:txn_id]).to eq("PAYPAL-TXN-123")
          expect(props[:payment_address]).to eq("seller@example.com")
          expect(props[:correlation_id]).to eq("CORR-123")
        end

        it "identifies PayPal processor correctly" do
          expect(props[:is_paypal_processor]).to be true
          expect(props[:is_stripe_processor]).to be false
          expect(props[:processor]).to eq(PayoutProcessorType::PAYPAL)
        end
      end

      context "when payment uses Stripe processor" do
        let(:payment) do
          create(:payment,
                 processor: PayoutProcessorType::STRIPE,
                 stripe_transfer_id: "tr_123456",
                 stripe_connect_account_id: "acct_123456")
        end

        it "includes Stripe-specific information" do
          expect(props[:stripe_transfer_id]).to eq("tr_123456")
          expect(props[:stripe_connect_account_id]).to eq("acct_123456")
          expect(props[:stripe_transfer_url]).to eq(
            StripeUrl.transfer_url("tr_123456", account_id: "acct_123456")
          )
          expect(props[:stripe_connected_account_url]).to eq(
            StripeUrl.connected_account_url("acct_123456")
          )
        end

        it "identifies Stripe processor correctly" do
          expect(props[:is_stripe_processor]).to be true
          expect(props[:is_paypal_processor]).to be false
          expect(props[:processor]).to eq(PayoutProcessorType::STRIPE)
        end
      end
    end

    describe "bank account information" do
      context "when payment has no bank account" do
        let(:payment) { create(:payment, bank_account: nil) }

        it "returns nil for bank_account" do
          expect(props[:bank_account]).to be_nil
        end
      end

      context "when payment has a bank account" do
        let(:bank_account) { create(:uk_bank_account) }
        let(:payment) { create(:payment, bank_account:) }

        it "returns bank account information" do
          bank_account_data = props[:bank_account]

          expect(bank_account_data).to be_a(Hash)
          expect(bank_account_data[:formatted_account]).to eq(bank_account.formatted_account)
        end

        context "when bank account has a credit card" do
          let(:credit_card) { instance_double(CreditCard, visual: "Visa ending in 1234") }

          before do
            allow(bank_account).to receive(:credit_card).and_return(credit_card)
          end

          it "includes the credit card visual" do
            expect(props[:bank_account][:credit_card][:visual]).to eq("Visa ending in 1234")
          end
        end

        context "when bank account has no credit card" do
          it "includes nil for credit card visual" do
            expect(props[:bank_account][:credit_card][:visual]).to be_nil
          end
        end
      end
    end
  end
end
