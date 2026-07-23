# frozen_string_literal: true

require "spec_helper"

describe RetryStripeRejectedPayoutSetupForSellerJob do
  let(:bank_prefix) { StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX }
  let(:postal_prefix) { StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX }
  let(:user) { create(:user, payment_address: nil) }
  let!(:user_compliance_info) { create(:user_compliance_info, user:) }

  def add_note(prefix, json: {})
    note = user.add_payout_note(content: "#{prefix}: some_code — some message")
    json.each { |key, value| note.json_data[key.to_s] = value }
    note.save!
    note
  end

  describe "bank account remediation" do
    let!(:merchant_account) { create(:merchant_account, user:) }
    let!(:note) { add_note(bank_prefix) }

    it "retries the bank sync quietly and resolves on success" do
      expect(StripeMerchantAccountManager).to receive(:update_bank_account)
        .with(user, hash_including(notify: false)).and_return(:synced)

      described_class.new.perform(user.id)

      expect(note.reload).not_to be_alive
      expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::RESOLVED_NOTE)
    end

    it "resolves when the bank account is already synced to Stripe" do
      expect(StripeMerchantAccountManager).to receive(:update_bank_account).and_return(:noop_metadata_match)

      described_class.new.perform(user.id)

      expect(note.reload).not_to be_alive
      expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::RESOLVED_NOTE)
    end

    it "records a retry attempt and keeps the note when the sync still fails" do
      expect(StripeMerchantAccountManager).to receive(:update_bank_account).and_return(:invalid_bank_account)

      described_class.new.perform(user.id)

      note.reload
      expect(note).to be_alive
      expect(note.json_data["retry_count"]).to eq(1)
      expect(note.json_data["last_retried_at"]).to be_present
    end

    it "abandons the retry loop when payments on the Stripe account are blocked at the platform level" do
      expect(StripeMerchantAccountManager).to receive(:update_bank_account).and_return(:account_blocked_by_platform)

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["abandoned_at"]).to be_present
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_ACCOUNT_BLOCKED)
      expect(note.json_data["retry_count"]).to be_nil
      expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::ACCOUNT_BLOCKED_NOTE)
    end
  end

  describe "bank account remediation when the seller has no Stripe account yet" do
    let!(:note) { add_note(bank_prefix) }

    it "re-attempts account creation so the bank account is resubmitted, not a bank-only update" do
      expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)
      expect(StripeMerchantAccountManager).to receive(:create_account)
        .with(user, hash_including(notify: false))

      described_class.new.perform(user.id)
    end
  end

  describe "postal code remediation" do
    context "when the seller already has an alive Stripe account" do
      let!(:merchant_account) { create(:merchant_account, user:) }
      let!(:note) { add_note(postal_prefix) }

      it "re-syncs the compliance info quietly and forces the address to be re-validated" do
        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)
          .with(user.alive_user_compliance_info, hash_including(notify: false, force_address_resync: true))

        described_class.new.perform(user.id)
      end
    end

    context "when the seller has no Stripe account yet" do
      let!(:note) { add_note(postal_prefix) }

      it "re-attempts account creation quietly" do
        expect(StripeMerchantAccountManager).to receive(:create_account)
          .with(user, hash_including(notify: false))

        described_class.new.perform(user.id)
      end
    end

    context "when remediation keeps failing and the marker is preserved" do
      let!(:merchant_account) { create(:merchant_account, user:) }
      let!(:note) { add_note(postal_prefix) }

      it "records a failed attempt without falsely resolving" do
        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).and_raise(
          Stripe::InvalidRequestError.new("The postal code you entered is not valid.", "person", code: "postal_code_invalid")
        )

        described_class.new.perform(user.id)

        expect(note.reload).to be_alive
        expect(note.json_data["retry_count"]).to eq(1)
        expect(user.comments.alive.with_type_payout_note.where("content LIKE ?", "#{described_class::RESOLVED_NOTE[0, 20]}%")).to be_empty
      end
    end
  end

  describe "giving up after exhausting retries" do
    it "abandons the note and emails the bank-tailored notice without attempting another sync" do
      note = add_note(bank_prefix, json: { retry_count: RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES })
      expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted).with(user.id, "bank")

      note.reload
      expect(note.json_data["abandoned_at"]).to be_present
      expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::GAVE_UP_NOTE)
    end

    it "emails the postal-tailored notice when the exhausted marker is a postal-code rejection" do
      add_note(postal_prefix, json: { retry_count: RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES })

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted).with(user.id, "postal")
    end
  end

  describe "when the seller has switched to a non-Stripe payout method" do
    before { user.update!(payment_address: "seller@example.com") }

    context "with a postal-code failure note and no Stripe account" do
      let!(:note) { add_note(postal_prefix) }

      it "abandons the note without recreating a Stripe account" do
        expect(StripeMerchantAccountManager).not_to receive(:create_account)

        described_class.new.perform(user.id)

        note.reload
        expect(note.json_data["abandoned_at"]).to be_present
        expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_SWITCHED_OFF_STRIPE)
        expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::SWITCHED_OFF_STRIPE_NOTE)
      end
    end

    context "with a bank failure note that already exhausted its retries" do
      let!(:note) { add_note(bank_prefix, json: { retry_count: RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES }) }

      it "abandons the note without emailing the seller that payouts may be blocked" do
        expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)

        described_class.new.perform(user.id)

        note.reload
        expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_SWITCHED_OFF_STRIPE)
        expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::SWITCHED_OFF_STRIPE_NOTE)
        expect(user.comments.alive.with_type_payout_note.where(content: described_class::GAVE_UP_NOTE)).to be_empty
      end
    end
  end

  describe "when the seller has connected their own Stripe account" do
    before { allow_any_instance_of(User).to receive(:has_stripe_account_connected?).and_return(true) }
    let!(:note) { add_note(bank_prefix) }

    it "abandons the note instead of re-enqueueing a no-op every sweep" do
      expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)
      expect(StripeMerchantAccountManager).not_to receive(:create_account)

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_CONNECTED_STRIPE)
      expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::CONNECTED_STRIPE_NOTE)
    end
  end

  describe "postal code remediation through the real Stripe update (regression for false resolve)" do
    include_context "with Stripe API stubs"

    let(:passphrase) { "1234" }
    let(:business_user) { create(:user, payment_address: nil) }
    let!(:tos_agreement) { create(:tos_agreement, user: business_user) }
    let!(:bank_account) { create(:ach_account, user: business_user) }
    let!(:business_compliance_info) { create(:user_compliance_info_business, user: business_user, zip_code: "94107") }

    before do
      StripeMerchantAccountManager.create_account(business_user, passphrase:)
      business_user.reload
      business_user.add_payout_note(
        content: "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}: postal_code_invalid — bad"
      )
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("STRONGBOX_GENERAL_PASSWORD").and_return(passphrase)
      allow(Stripe::Account).to receive(:update_person) do |_account_id, person_id, params|
        if params.is_a?(Hash) && params.dig(:address, :postal_code).present?
          raise Stripe::InvalidRequestError.new(
            "The postal code you entered is not valid.", "person[address][postal_code]", code: "postal_code_invalid"
          )
        end
        Stripe::StripeObject.construct_from(id: person_id, object: "person")
      end
    end

    it "does not resolve when the forced postal resync is still rejected by Stripe" do
      described_class.new.perform(business_user.id)

      note = business_user.comments.alive.with_type_payout_note
        .where("content LIKE ?", "#{postal_prefix}%").last
      expect(note).to be_present
      expect(note.json_data["retry_count"]).to eq(1)
      expect(business_user.comments.alive.with_type_payout_note.where(content: described_class::RESOLVED_NOTE)).to be_empty
    end
  end

  it "does nothing for a suspended seller" do
    add_note(bank_prefix)
    allow_any_instance_of(User).to receive(:suspended?).and_return(true)

    expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)

    described_class.new.perform(user.id)
  end

  it "does nothing when the seller has no outstanding failure note" do
    expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)

    described_class.new.perform(user.id)
  end
end
