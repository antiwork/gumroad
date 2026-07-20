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

  describe "bank account rejection during account creation" do
    let(:zip_code) { "94107" }

    context "when Stripe rejects the bank account (directory gap / invalid number)" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "We couldn't find the bank for that routing number", "bank_account[routing_number]", code: "routing_number_invalid"
          )
        )
      end

      it "records a bank sync failure note and re-raises" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).count).to eq(1)
      end

      it "does not record a payout note when notify is false" do
        expect do
          described_class.create_account(user, passphrase:, notify: false)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)).to be_empty
      end

      it "does not report the rejection to Sentry (expected seller-input error)" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(ErrorNotifier).not_to have_received(:notify)
      end
    end

    context "when Stripe rejects the external account with a card error" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::CardError.new("Your card does not support this type of purchase.", "external_account", code: "card_decline_rate_limit_exceeded")
        )
      end

      it "records a bank sync failure note and re-raises" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::CardError)

        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).count).to eq(1)
      end
    end

    context "when account creation fails for a non-bank reason" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new("US tax IDs must have 9 digits", "individual[id_number]", code: "tax_id_invalid")
        )
      end

      it "does not record a bank sync failure note" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)).to be_empty
      end
    end

    context "when account creation succeeds" do
      it "clears stale bank sync rejection notes" do
        stale = user.add_payout_note(
          content: "#{StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX}: routing_number_invalid — We couldn't find the bank for that routing number."
        )

        described_class.create_account(user, passphrase:)

        expect(stale.reload).not_to be_alive
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

  describe "account holder name rejection stays out of the retry loop" do
    let(:zip_code) { "94107" }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
      merchant_id = user.stripe_account.charge_processor_merchant_id
      allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(
        Stripe::Account.construct_from(id: merchant_id, metadata: {}, external_accounts: { object: "list", data: [] })
      )
      allow(Stripe::Account).to receive(:update).and_raise(
        Stripe::InvalidRequestError.new("Account holder name is invalid", "account_holder_name", code: "incorrect_account_holder_name")
      )
    end

    it "emails the seller but records no retryable failure note, since a name mismatch never self-heals" do
      result = nil
      expect do
        result = described_class.update_bank_account(user, passphrase:)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_account_holder_name).with(user.id)

      expect(result).to eq(:invalid_account_holder_name)
      expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)).to be_empty
    end
  end

  describe "forcing an address resync on an automated retry" do
    let(:zip_code) { "94107" }
    let!(:business_compliance_info) { create(:user_compliance_info_business, user:) }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
    end

    def captured_address_postal_codes
      account_params = []
      person_params = []
      allow(Stripe::Account).to receive(:update) do |account_id, params|
        account_params << params
        Stripe::Account.construct_from(
          id: account_id, object: "account", metadata: params[:metadata] || {},
          external_accounts: { object: "list", data: [] }, requirements: { "currently_due" => [], "past_due" => [] }
        )
      end
      allow(Stripe::Account).to receive(:update_person) do |_account_id, person_id, params|
        person_params << params
        Stripe::StripeObject.construct_from(id: person_id, object: "person")
      end
      yield
      account_postals = account_params.filter_map { |p| p.is_a?(Hash) ? (p.dig(:company, :address, :postal_code) || p.dig(:individual, :address, :postal_code)) : nil }
      person_postals = person_params.filter_map { |p| p.is_a?(Hash) ? p.dig(:address, :postal_code) : nil }
      [account_postals, person_postals]
    end

    it "diffs out the unchanged postal code without the flag" do
      account_postals, person_postals = captured_address_postal_codes do
        described_class.update_account(user, passphrase:)
      end

      expect(account_postals).to be_empty
      expect(person_postals).to be_empty
    end

    it "re-sends the company and representative postal codes when force_address_resync is set" do
      account_postals, person_postals = captured_address_postal_codes do
        described_class.update_account(user, passphrase:, force_address_resync: true)
      end

      expect(account_postals).to be_present
      expect(person_postals).to be_present
    end
  end

  describe "postal code note clearing on account update for a business account" do
    let(:zip_code) { "94107" }
    let!(:business_compliance_info) { create(:user_compliance_info_business, user:) }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
    end

    it "keeps the postal-code note when the account update succeeds but a later person update fails for an unrelated reason" do
      note = user.add_payout_note(
        content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — The postal code you entered is not valid."
      )
      allow(Stripe::Account).to receive(:update_person).and_raise(
        Stripe::InvalidRequestError.new("Representative information is invalid", "person")
      )

      expect { described_class.update_account(user, passphrase:) }.to raise_error(Stripe::InvalidRequestError)
      expect(note.reload).to be_alive
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

    it "keeps the postal-code note when a non-forced update succeeds without re-sending the address" do
      note = user.add_payout_note(
        content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — The postal code you entered is not valid."
      )

      described_class.update_account(user, passphrase:)

      expect(note.reload).to be_alive
    end

    it "clears the postal-code note when force_address_resync re-sends and re-validates the address" do
      note = user.add_payout_note(
        content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — The postal code you entered is not valid."
      )

      described_class.update_account(user, passphrase:, force_address_resync: true)

      expect(note.reload).not_to be_alive
    end

    it "clears the postal-code note when a business seller's corrected address is submitted and accepted on a non-forced update" do
      note = user.add_payout_note(
        content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — The postal code you entered is not valid."
      )
      create(:user_compliance_info_business, user:, zip_code: "10001")

      described_class.update_account(user, passphrase:)

      expect(note.reload).not_to be_alive
    end
  end
end
