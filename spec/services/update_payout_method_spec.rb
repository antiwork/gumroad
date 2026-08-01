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

        it "normalizes ASCII spaces to full-width and enqueues HandleNewBankAccountWorker" do
          params = ActionController::Parameters.new(
            bank_account: { type: JapanBankAccount.name, account_holder_full_name: "ハルナ マサシ" }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result).to eq(success: true)
          end.to change { HandleNewBankAccountWorker.jobs.size }.by(1)

          expect(bank_account.reload.account_holder_full_name).to eq("ハルナ　マサシ")
        end

        it "syncs a pre-validator invalid stored ASCII-space name when the seller re-saves it" do
          bank_account.update_columns(account_holder_full_name: "ハルナ マサシ")

          params = ActionController::Parameters.new(
            bank_account: { type: JapanBankAccount.name, account_holder_full_name: "ハルナ マサシ" }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result).to eq(success: true)
          end.to change { HandleNewBankAccountWorker.jobs.size }.by(1)

          expect(bank_account.reload.account_holder_full_name).to eq("ハルナ　マサシ")
        end

        it "returns a validation error and does not enqueue HandleNewBankAccountWorker when the name mixes scripts" do
          params = ActionController::Parameters.new(
            bank_account: { type: JapanBankAccount.name, account_holder_full_name: "Haruna マサシ" }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result[:error]).to eq(:bank_account_error)
          end.not_to change { HandleNewBankAccountWorker.jobs.size }

          expect(bank_account.reload.account_holder_full_name).to eq("Japanese Creator")
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

        {
          VietnamBankAccount => :vietnam_bank_account,
          IndonesiaBankAccount => :indonesia_bank_account,
        }.each do |klass, factory|
          it "does not enqueue HandleNewBankAccountWorker for #{klass.name.gsub('BankAccount', '')} when the submitted name differs only by surrounding whitespace" do
            user = create(:named_user)
            bank_account = create(factory, user:, account_holder_full_name: "Pham Minh")
            create(:user_compliance_info, user:, country: klass == VietnamBankAccount ? "Vietnam" : "Indonesia")

            params = ActionController::Parameters.new(
              bank_account: { type: klass.name, account_holder_full_name: "Pham Minh " }
            )

            expect do
              result = described_class.new(user_params: params, seller: user).process
              expect(result).to eq(success: true)
            end.not_to change { HandleNewBankAccountWorker.jobs.size }

            expect(bank_account.reload.account_holder_full_name).to eq("Pham Minh")
          end
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

    describe "when the IBAN is pasted with invisible separator characters" do
      let(:user) { create(:named_user) }

      before { allow(Rails.env).to receive(:production?).and_return(true) }

      it "strips non-breaking and zero-width characters so a valid IBAN is accepted and stored clean" do
        clean_iban = "BH29BMAG1299123456BH00"
        non_breaking_space = [0x00A0].pack("U")
        zero_width_space = [0x200B].pack("U")
        pasted_iban = "BH29#{non_breaking_space}BMAG#{zero_width_space}1299123456BH00"

        params = ActionController::Parameters.new(
          bank_account: {
            type: BahrainBankAccount.name,
            account_holder_full_name: "Named User",
            bank_code: "AAAABHBMXYZ",
            account_number: pasted_iban,
            account_number_confirmation: pasted_iban,
          }
        )

        result = described_class.new(user_params: params, seller: user).process

        expect(result).to eq(success: true)
        bank_account = user.reload.active_bank_account
        expect(bank_account).to be_a(BahrainBankAccount)
        expect(bank_account.send(:account_number_decrypted)).to eq(clean_iban)
        expect(bank_account.account_number_last_four).to eq("BH00")
      end

      it "strips the hyphens New Zealand account numbers are printed with" do
        # New Zealand numbers are written bank-branch-account-suffix with hyphens on statements and
        # in banking apps, so this is the form a seller copies. The model wants the bare 16 digits.
        params = ActionController::Parameters.new(
          bank_account: {
            type: NewZealandBankAccount.name,
            account_holder_full_name: "Named User",
            account_number: "11-0000-00000000-10",
            account_number_confirmation: "11-0000-00000000-10",
          }
        )

        result = described_class.new(user_params: params, seller: user).process

        expect(result).to eq(success: true)
        bank_account = user.reload.active_bank_account
        expect(bank_account).to be_a(NewZealandBankAccount)
        expect(bank_account.send(:account_number_decrypted)).to eq("1100000000000010")
        expect(bank_account.account_number_last_four).to eq("0010")
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

    describe "saving a PayPal address PayPal has permanently refused" do
      let(:user) { create(:named_user) }
      let(:params) { ActionController::Parameters.new(payment_address: "refused@example.com") }

      before do
        create(:payment_failed, user:, payment_address: "refused@example.com",
                                failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil)
        user.update!(payment_address: "", invalidated_paypal_payout_address: "refused@example.com")
      end

      # Accepting it would put the seller straight back behind the payout block, with their settings
      # page once again claiming they have a working payout method (gumroad-private#1478).
      it "is refused, and the account is left alone" do
        result = described_class.new(user_params: params, seller: user).process

        expect(result).to eq(error: :paypal_address_permanently_refused)
        expect(user.reload.payment_address).to be_blank
        expect(user.invalidated_paypal_payout_address).to eq("refused@example.com")
      end

      # A different address has no rejection standing against it, and once the seller has chosen a
      # payout method the record of the one we removed has done its job.
      it "accepts a different address and clears the record of the removed one" do
        params = ActionController::Parameters.new(payment_address: "working@example.com")

        result = described_class.new(user_params: params, seller: user).process

        expect(result).to eq(success: true)
        expect(user.reload.payment_address).to eq("working@example.com")
        expect(user.invalidated_paypal_payout_address).to be_blank
      end

      # A currency rejection is repairable on the same account, so re-saving that address is a
      # legitimate thing for a seller to do after fixing it.
      it "accepts an address whose only rejection was a currency one" do
        user.payments.each { |payment| payment.update!(failure_reason: "PAYPAL 14159") }

        result = described_class.new(user_params: params, seller: user).process

        expect(result).to eq(success: true)
        expect(user.reload.payment_address).to eq("refused@example.com")
      end

      # Switching to a bank account resolves the situation just as much as saving a working PayPal
      # address does. Leaving the record set would let the old rejection come back as this account's
      # live situation the moment the bank account goes away — UpdateUserCountry deletes it, so that
      # is reachable, and the seller would be blocked by a rejection of an address they no longer use.
      it "clears the record of the removed address when the seller switches to a bank account" do
        bank_params = ActionController::Parameters.new(
          bank_account: {
            type: AchAccount.name, account_number: "000123456789", account_number_confirmation: "000123456789",
            routing_number: "110000000", account_holder_full_name: "Gum Road"
          }
        )

        result = described_class.new(user_params: bank_params, seller: user).process

        expect(result).to eq(success: true)
        expect(user.reload.invalidated_paypal_payout_address).to be_blank
        # Asserted with the bank account gone, since its mere presence short-circuits the block —
        # asserting while it is alive would pass no matter what the record holds.
        user.bank_accounts.alive.each(&:mark_deleted!)
        expect(PaypalPayoutProcessor.terminal_failure_blocking_payouts?(user.reload)).to eq(false)
      end
    end
  end
end
