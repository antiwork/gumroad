# frozen_string_literal: true

require "spec_helper"

describe UpdatePayoutMethod do
  describe "#process" do
    describe "updating only the account holder name" do
      let(:user) { create(:named_user) }

      context "when the seller is in a country that syncs holder name to Stripe" do
        let!(:bank_account) { create(:japan_bank_account, user:) }
        let!(:compliance_info) { create(:user_compliance_info, user:, country: "Japan") }

        it "saves the name and enqueues HandleNewBankAccountWorker" do
          params = ActionController::Parameters.new(
            bank_account: { type: JapanBankAccount.name, account_holder_full_name: "ヤマダ\u3000タロウ" }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result).to eq(success: true)
          end.to change { HandleNewBankAccountWorker.jobs.size }.by(1)

          expect(bank_account.reload.account_holder_full_name).to eq("ヤマダ\u3000タロウ")
        end

        it "returns a validation error and does not enqueue HandleNewBankAccountWorker when the new name mixes scripts" do
          params = ActionController::Parameters.new(
            bank_account: { type: JapanBankAccount.name, account_holder_full_name: "ハルナ マサシ" }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result[:error]).to eq(:bank_account_error)
          end.not_to change { HandleNewBankAccountWorker.jobs.size }

          expect(bank_account.reload.account_holder_full_name).to eq("Japanese Creator")
        end

        it "surfaces a validation error when the submitted name equals a pre-validator invalid stored name" do
          bank_account.update_columns(account_holder_full_name: "ハルナ マサシ")

          params = ActionController::Parameters.new(
            bank_account: { type: JapanBankAccount.name, account_holder_full_name: "ハルナ マサシ" }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result[:error]).to eq(:bank_account_error)
          end.not_to change { HandleNewBankAccountWorker.jobs.size }
        end

        it "does not enqueue HandleNewBankAccountWorker when the submitted name differs only by surrounding whitespace" do
          params = ActionController::Parameters.new(
            bank_account: { type: JapanBankAccount.name, account_holder_full_name: "Japanese Creator " }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result).to eq(success: true)
          end.not_to change { HandleNewBankAccountWorker.jobs.size }

          expect(bank_account.reload.account_holder_full_name).to eq("Japanese Creator")
        end
      end

      context "when the seller is in a country that does NOT sync holder name to Stripe" do
        let!(:bank_account) { create(:ach_account, user:, account_holder_full_name: "Old Name") }

        it "saves the name without enqueueing HandleNewBankAccountWorker" do
          params = ActionController::Parameters.new(
            bank_account: { type: AchAccount.name, account_holder_full_name: "New Name" }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result).to eq(success: true)
          end.not_to change { HandleNewBankAccountWorker.jobs.size }

          expect(bank_account.reload.account_holder_full_name).to eq("New Name")
        end
      end
    end

    describe "replacing the active bank account" do
      let(:user) { create(:named_user) }
      let!(:existing_bank_account) { create(:ach_account, user:) }

      context "when the new bank account fails validation" do
        it "returns bank_account_error and keeps the existing bank account alive" do
          params = ActionController::Parameters.new(
            bank_account: {
              type: AchAccount.name,
              account_holder_full_name: "",
              account_number: "123456789",
              account_number_confirmation: "123456789",
              routing_number: "110000000",
            }
          )

          result = described_class.new(user_params: params, seller: user).process

          expect(result[:error]).to eq(:bank_account_error)
          expect(user.bank_accounts.alive.count).to eq(1)
          expect(user.active_bank_account).to eq(existing_bank_account)
        end
      end

      context "when the user already has multiple alive bank accounts" do
        let!(:orphaned_bank_account) { create(:ach_account, user:) }

        it "deletes all existing alive bank accounts and does not report an inconsistency" do
          params = ActionController::Parameters.new(
            bank_account: {
              type: AchAccount.name,
              account_holder_full_name: "Named User",
              account_number: "123456789",
              account_number_confirmation: "123456789",
              routing_number: "110000000",
            }
          )

          allow(ErrorNotifier).to receive(:notify)

          result = described_class.new(user_params: params, seller: user).process

          expect(result).to eq(success: true)
          expect(user.bank_accounts.alive.count).to eq(1)
          expect(existing_bank_account.reload.deleted_at).to be_present
          expect(orphaned_bank_account.reload.deleted_at).to be_present
          expect(ErrorNotifier).not_to have_received(:notify)
        end
      end

    end

    describe "when account number exceeds maximum length" do
      let(:user) { create(:named_user) }

      it "returns an error without attempting RSA encryption" do
        oversized_number = "1" * 201
        params = ActionController::Parameters.new(
          bank_account: {
            type: AchAccount.name,
            account_holder_full_name: "Named User",
            account_number: oversized_number,
            account_number_confirmation: oversized_number,
            routing_number: "110000000",
          }
        )

        result = described_class.new(user_params: params, seller: user).process

        expect(result[:error]).to eq(:bank_account_error)
        expect(result[:data]).to eq("Account number is too long")
      end
    end

    describe "switching to card payouts" do
      let(:user) { create(:named_user) }
      let!(:existing_bank_account) { create(:ach_account, user:) }
      let(:concurrent_bank_account) { instance_double(BankAccount, id: existing_bank_account.id + 1) }
      let(:prepared_credit_card) { instance_double(CreditCard, destroy!: true) }
      let(:params) { ActionController::Parameters.new(card: { token: "tok_123" }) }
      subject(:service) { described_class.new(user_params: params, seller: user) }

      before do
        allow(service).to receive(:prepare_credit_card).and_return([prepared_credit_card, nil])
        allow(user).to receive(:active_bank_account).and_return(existing_bank_account, concurrent_bank_account)
      end

      it "discards the prepared credit card when a concurrent payout-method change wins the race" do
        expect(prepared_credit_card).to receive(:destroy!)

        expect(service.process).to eq(error: :concurrent_payout_method_change)
      end

      it "discards the prepared credit card when an exception escapes after card preparation" do
        allow(user).to receive(:active_bank_account).and_return(existing_bank_account, existing_bank_account)
        allow(service).to receive(:process_card_params).with(prepared_credit_card).and_raise("boom")

        expect(prepared_credit_card).to receive(:destroy!)

        expect { service.process }.to raise_error(RuntimeError, "boom")
      end
    end
  end
end
