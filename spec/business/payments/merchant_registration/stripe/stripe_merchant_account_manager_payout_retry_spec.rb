# frozen_string_literal: true

require "spec_helper"

describe StripeMerchantAccountManager do
  include_context "with Stripe API stubs"

  let(:passphrase) { "1234" }
  let(:user) { create(:user) }
  let!(:tos_agreement) { create(:tos_agreement, user:) }
  let!(:bank_account) { create(:ach_account, user:) }
  let!(:user_compliance_info) { create(:user_compliance_info, user:, zip_code:) }

  def payout_notes(prefix)
    user.comments.alive.with_type_payout_note.where("content LIKE ?", "#{prefix}%")
  end

  describe "postal code rejection during account creation" do
    context "when Stripe rejects the postal code" do
      let(:zip_code) { "not-a-zip" }

      it "records a postal code rejection payout note and re-raises" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX).count).to eq(1)
      end

      it "does not record a payout note when notify is false" do
        expect do
          described_class.create_account(user, passphrase:, notify: false)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX)).to be_empty
      end
    end

    context "when account creation succeeds" do
      let(:zip_code) { "94107" }

      it "clears stale postal code rejection notes and leaves unrelated notes alone" do
        stale = user.add_payout_note(
          content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — The postal code you entered is not valid."
        )
        unrelated = user.add_payout_note(content: "Scheduled payouts paused on May 1, 2026")

        described_class.create_account(user, passphrase:)

        expect(stale.reload).not_to be_alive
        expect(unrelated.reload).to be_alive
      end
    end
  end

  describe "bank sync rejection notify flag" do
    let(:zip_code) { "94107" }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
      merchant_id = user.stripe_account.charge_processor_merchant_id
      allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(
        Stripe::Account.construct_from(id: merchant_id, metadata: {}, external_accounts: { object: "list", data: [] })
      )
      allow(Stripe::Account).to receive(:update).and_raise(
        Stripe::InvalidRequestError.new("Invalid account number", "invalid_account_number")
      )
    end

    it "suppresses the seller email and failure note when notify is false" do
      result = nil
      expect do
        result = described_class.update_bank_account(user, passphrase:, notify: false)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)

      expect(result).to eq(:invalid_bank_account)
      expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)).to be_empty
    end

    it "emails the seller and records a failure note by default" do
      expect do
        described_class.update_bank_account(user, passphrase:)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account).with(user.id)

      expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).count).to eq(1)
    end
  end

  describe "postal code note clearing on account update for a business account" do
    let(:zip_code) { "94107" }
    let!(:business_compliance_info) { create(:user_compliance_info_business, user:) }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
    end

    it "clears the postal-code note when the account update succeeds but a later person update fails for an unrelated reason" do
      note = user.add_payout_note(
        content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — The postal code you entered is not valid."
      )
      allow(Stripe::Account).to receive(:update_person).and_raise(
        Stripe::InvalidRequestError.new("Representative information is invalid", "person")
      )

      expect { described_class.update_account(user, passphrase:) }.to raise_error(Stripe::InvalidRequestError)
      expect(note.reload).not_to be_alive
    end

    it "keeps the postal-code note when the person update is itself rejected for an invalid postal code" do
      note = user.add_payout_note(
        content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — The postal code you entered is not valid."
      )
      allow(Stripe::Account).to receive(:update_person).and_raise(
        Stripe::InvalidRequestError.new("The postal code you entered is not valid.", "person[address][postal_code]", code: "postal_code_invalid")
      )

      expect { described_class.update_account(user, passphrase:, notify: false) }.to raise_error(Stripe::InvalidRequestError)
      expect(note.reload).to be_alive
    end
  end
end
