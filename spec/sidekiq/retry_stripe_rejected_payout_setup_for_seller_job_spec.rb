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

  describe "bank code rejected on format" do
    let!(:merchant_account) { create(:merchant_account, user:) }

    def add_format_rejection_note(content)
      note = user.add_payout_note(content: "#{bank_prefix}: #{content}")
      note.json_data["seller_notified"] = true
      note.save!
      note
    end

    it "stops retrying immediately instead of re-sending the same rejected code" do
      note = add_format_rejection_note("routing_number_invalid — Invalid routing number for PK. The number must contain both the bank code and the branch code, and should be in the format AAAAPKBB or AAAAPKBBXYZ.")
      expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["abandoned_at"]).to be_present
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_FORMAT_REJECTION)
      expect(note.json_data["retry_count"]).to be_nil
      expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::BANK_FORMAT_REJECTION_NOTE)
    end

    it "does not email the seller that retries were exhausted" do
      # Seeded at the retry ceiling so that WITHOUT the early exit this note would fall through
      # to give_up!, which does send the exhausted email — otherwise the assertion passes for
      # the wrong reason (a fresh note can't reach give_up! anyway).
      note = add_format_rejection_note("account_number_invalid — Invalid account number")
      note.json_data["retry_count"] = RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES
      note.save!

      expect do
        described_class.new.perform(user.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted)

      expect(note.reload.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_FORMAT_REJECTION)
    end

    it "keeps retrying a directory miss, which waiting can genuinely fix" do
      note = add_format_rejection_note("routing_number_invalid — We couldn't find the bank for that BIC")
      # The code alone would classify this as a format rejection, so make sure the retry loop
      # still runs for the directory-miss message that Stripe sends with the same code.
      expect(StripeMerchantAccountManager).to receive(:update_bank_account).and_return(:invalid_bank_account)

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["abandoned_at"]).to be_blank
      expect(note.json_data["retry_count"]).to eq(1)
    end

    it "emails the seller before abandoning a note recorded without notifying them" do
      # Account creation records a bank-sync note and re-raises rather than emailing, so a note
      # can reach the retry loop with the seller never having been told.
      note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — Invalid routing number for PK. The number must contain both the bank code and the branch code, and should be in the format AAAAPKBB or AAAAPKBBXYZ.")

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
        .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT, note.content)

      note.reload
      expect(note.json_data["seller_notified"]).to be(true)
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_FORMAT_REJECTION)
    end

    it "does not re-email a seller who was already notified at rejection time" do
      add_format_rejection_note("routing_number_invalid — Invalid routing number for PK. Should be in the format AAAAPKBB.")

      expect do
        described_class.new.perform(user.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
    end

    it "commits the notification marker together with the abandonment, so a replay cannot re-email" do
      # Without the marker being part of the abandonment transaction, a run that dies partway
      # leaves the note unabandoned AND unmarked, so the next run re-selects it and emails the
      # seller a second time. Simulate the crash by failing the audit note inside the transaction.
      note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — Invalid routing number for PK. Should be in the format AAAAPKBB.")
      allow(user).to receive(:add_payout_note).and_call_original
      allow(User).to receive(:find_by).with(id: user.id).and_return(user)
      allow(user).to receive(:add_payout_note).with(content: described_class::BANK_FORMAT_REJECTION_NOTE).and_raise(ActiveRecord::RecordInvalid.new(Comment.new))

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["abandoned_at"]).to be_blank
      # The marker rolled back with the abandonment rather than being stranded as a lone write,
      # so the state is self-consistent: nothing was concluded about this note in that pass.
      expect(note.json_data["seller_notified"]).to be_blank
    end

    it "classifies from the stored Stripe error message rather than the truncated note text" do
      long_directory_miss = "Stripe could not validate the submitted bank details for this connected account. " \
                            "#{'Diagnostic context. ' * 8}We couldn't find the bank for that BIC"
      note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — #{long_directory_miss.truncate(200)}")
      note.json_data["stripe_error_code"] = "routing_number_invalid"
      note.json_data["stripe_error_message"] = long_directory_miss
      note.json_data["seller_notified"] = true
      note.save!
      # The directory-miss phrase sits past the note's 200-char truncation, so a text sniffer
      # would misread this as a format rejection and kill a retry that can still succeed.
      expect(StripeMerchantAccountManager).to receive(:update_bank_account).and_return(:invalid_bank_account)

      described_class.new.perform(user.id)

      expect(note.reload.json_data["abandoned_at"]).to be_blank
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
