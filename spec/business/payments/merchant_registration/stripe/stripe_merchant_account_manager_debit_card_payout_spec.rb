# frozen_string_literal: true

require "spec_helper"

# Regression coverage for GUMROAD-50: submitting a debit card (rather than a bank
# account) as a payout destination makes Stripe raise a Stripe::InvalidRequestError
# with the message "This card doesn't appear to support payouts." and no specific
# error code (there is no bank_account_unusable code). That case must be handled as
# an invalid bank account instead of falling through to ErrorNotifier as an
# unhandled internal error.
describe StripeMerchantAccountManager do
  let(:user) { create(:user) }

  describe "#update_bank_account" do
    before do
      create(:user_compliance_info, user:)
      create(:merchant_account, user:)
      create(:ach_account_stripe_succeed, user:)
    end

    context "when a debit card is submitted as a payout destination" do
      before do
        stripe_account = Stripe::Account.construct_from(id: "acct_debit_card", metadata: {})
        allow(Stripe::Account).to receive(:retrieve).and_return(stripe_account)
        error_message = "This card doesn't appear to support payouts."
        allow(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new(error_message, "external_account"))
      end

      it "emails the creator and returns invalid_bank_account without notifying ErrorNotifier" do
        expect(ErrorNotifier).not_to receive(:notify)

        result = nil
        expect do
          result = described_class.update_bank_account(user, passphrase: "1234")
        end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account).with(user.id)
        expect(result).to eq(:invalid_bank_account)
      end
    end
  end
end
