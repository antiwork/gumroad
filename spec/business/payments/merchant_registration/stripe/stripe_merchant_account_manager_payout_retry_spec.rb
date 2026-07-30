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

  # A seller with no connected account yet fails in create_account, which is the path the
  # payments settings page uses once a bank account exists. Every rejection there used to leave
  # nothing behind but a merchant-account row created and soft-deleted in the same second, so
  # support could not tell which field Stripe objected to (gumroad-private#1429).
  describe "account rejection breadcrumb during account creation" do
    let(:zip_code) { "94107" }

    def rejection_notes
      payout_notes(StripeMerchantAccountManager::ACCOUNT_REJECTION_NOTE_PREFIX)
    end

    context "when Stripe rejects a field we do not handle specifically" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "Invalid value for individual[id_number]", "individual[id_number]", code: "invalid_request_error"
          )
        )
      end

      it "records the rejected field and code as a private payout note, and re-raises" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        note = rejection_notes.last
        expect(note).to be_present
        expect(note.content).to include("code=invalid_request_error")
        expect(note.content).to include("param=individual[id_number]")
        expect(note.content).to include("Invalid value for individual[id_number]")
      end

      it "keeps the note private to staff" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(rejection_notes.last.json_data["seller_visible"]).to be false
      end

      it "does not record a note when notify is false" do
        expect do
          described_class.create_account(user, passphrase:, notify: false)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(rejection_notes).to be_empty
      end
    end

    context "when Stripe rejects the postal code" do
      let(:zip_code) { "not-a-zip" }

      it "leaves only the dedicated postal-code note, which drives the automatic retry" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(rejection_notes).to be_empty
        expect(payout_notes(StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX).count).to eq(1)
      end
    end

    context "when Stripe rejects the bank account" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "We couldn't find the bank for that routing number", "bank_account[routing_number]", code: "routing_number_invalid"
          )
        )
      end

      it "leaves only the dedicated bank sync note" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(rejection_notes).to be_empty
        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).count).to eq(1)
      end
    end

    # A note saying "Stripe rejected your payout setup" is only true when Stripe actually looked at
    # the seller's data and objected. If the request never reached Stripe, or Stripe throttled us, or
    # our own API key was wrong, then nothing about the seller was refused — writing a rejection note
    # anyway would send support hunting for a bad field that does not exist, on an account that may
    # well succeed on the next attempt. These errors are ours to fix, so they belong in Sentry (which
    # already gets them) and not on the seller's account.
    context "when the Stripe call fails without Stripe reaching a verdict" do
      transient_failures = {
        "a connection failure" => -> { Stripe::APIConnectionError.new("Unexpected error communicating with Stripe") },
        "rate limiting" => -> { Stripe::RateLimitError.new("Too many requests") },
        "a bad API key" => -> { Stripe::AuthenticationError.new("Invalid API Key provided") },
      }

      transient_failures.each do |description, build_error|
        context "on #{description}" do
          before do
            allow(Stripe::Account).to receive(:create).and_raise(build_error.call)
            allow(ErrorNotifier).to receive(:notify)
          end

          it "records no rejection note and re-raises" do
            expect do
              described_class.create_account(user, passphrase:)
            end.to raise_error(build_error.call.class)

            expect(rejection_notes).to be_empty
          end
        end
      end
    end

    context "when the breadcrumb itself fails to save" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new("Invalid value for individual[id_number]", "individual[id_number]")
        )
        allow_any_instance_of(User).to receive(:add_payout_note).and_raise(StandardError, "note write failed")
      end

      it "still raises Stripe's error rather than ours" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError, /individual\[id_number\]/)
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

      it "names the bank row Stripe rejected, so the settings banner can't blame a replacement" do
        # SettingsPresenter#current_bank_sync_failure_note keys off this. Without it the note is
        # indistinguishable from a legacy one and falls back to a timestamp comparison, which a
        # rejection landing after the seller re-saved details wins — blaming the new row.
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        note = payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).last
        expect(note.json_data["bank_account_id"]).to eq(bank_account.id)
      end

      it "carries the attribution from the note's first save, never a follow-up write" do
        # The note is readable the moment it is inserted, so an id written by a second save leaves
        # a window in which the banner treats it as unattributed. Assert the shape, not the odds:
        # one INSERT and no UPDATE means there is no such window.
        statements = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          statements << payload[:sql] if payload[:sql]&.match?(/\A(INSERT INTO|UPDATE) `comments`/)
        end

        begin
          expect do
            described_class.create_account(user, passphrase:)
          end.to raise_error(Stripe::InvalidRequestError)
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        expect(statements.grep(/\AINSERT INTO `comments`/).count).to eq(1)
        expect(statements.grep(/\AUPDATE `comments`/)).to be_empty
        # Asserted here too, so this example pins atomic ATTRIBUTION rather than just "no comment
        # updates happened".
        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).last.json_data["bank_account_id"]).to eq(bank_account.id)
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

    context "when Stripe rejects the tax ID as a disallowed placeholder value" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "Invalid Tax ID. 123456789 is not an allowed value.", nil
          )
        )
      end

      it "does not report the rejection to Sentry (expected seller-input error) and re-raises" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(ErrorNotifier).not_to have_received(:notify)
      end

      it "does not record a bank sync failure payout note" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)).to be_empty
      end
    end

    context "when Stripe rejects the phone number" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            '"+15550001" is not a valid phone number', nil
          )
        )
      end

      it "does not report the rejection to Sentry (expected seller-input error) and re-raises" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(ErrorNotifier).not_to have_received(:notify)
      end

      it "does not record a bank sync failure payout note" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)).to be_empty
      end
    end

    context "when Stripe rejects a Japanese address as unresolvable in its postal directory" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "Invalid address for Japan. We cannot find an address with town of Example-Cho 1-2-3 for postal_code 1000001.", nil
          )
        )
      end

      it "does not report the rejection to Sentry (expected seller-input error) and re-raises" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(ErrorNotifier).not_to have_received(:notify)
      end

      it "does not record a bank sync failure payout note" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)).to be_empty
      end
    end

    context "when Stripe rejects a tax-ID param without the message shape" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "Invalid value provided", "individual[id_number]"
          )
        )
      end

      it "does not report the rejection to Sentry" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(ErrorNotifier).not_to have_received(:notify)
      end
    end

    context "when Stripe rejects a phone param without the message shape" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "Invalid value provided", "individual[phone]"
          )
        )
      end

      it "does not report the rejection to Sentry" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(ErrorNotifier).not_to have_received(:notify)
      end
    end

    context "when Stripe rejects the bank as unsupported (no code or param on the error)" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "Stripe is unable to support this bank at this time.", nil
          )
        )
      end

      it "does not report the rejection to Sentry (expected seller-input error) and re-raises" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(ErrorNotifier).not_to have_received(:notify)
      end

      it "records a bank sync failure note" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).count).to eq(1)
      end
    end

    context "when Stripe rejects the postal code" do
      before do
        allow(Stripe::Account).to receive(:create).and_raise(
          Stripe::InvalidRequestError.new(
            "Invalid NL postal code", "individual[address][postal_code]", code: "postal_code_invalid"
          )
        )
      end

      it "does not report the rejection to Sentry (expected seller-input error, auto-retried weekly) and re-raises" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(ErrorNotifier).not_to have_received(:notify)
      end

      it "records a postal code failure note" do
        expect do
          described_class.create_account(user, passphrase:)
        end.to raise_error(Stripe::InvalidRequestError)

        expect(payout_notes(StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX).count).to eq(1)
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

        notes = payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX)
        expect(notes.count).to eq(1)
        expect(notes.last.json_data["bank_account_id"]).to eq(bank_account.id)
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
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
        .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT, "Invalid account number")

      expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).count).to eq(1)
    end
  end

  describe "bank directory rejection during a bank account sync" do
    let(:zip_code) { "94107" }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
      merchant_id = user.stripe_account.charge_processor_merchant_id
      allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(
        Stripe::Account.construct_from(id: merchant_id, metadata: {}, external_accounts: { object: "list", data: [] })
      )
      allow(Stripe::Account).to receive(:update).and_raise(
        Stripe::InvalidRequestError.new(
          "We couldn't find the bank for that BIC", "bank_account[routing_number]"
        )
      )
    end

    it "treats the rejection as an expected seller-input error without paging Sentry" do
      allow(ErrorNotifier).to receive(:notify)

      result = nil
      expect do
        result = described_class.update_bank_account(user, passphrase:)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
        .with(user.id, nil, "We couldn't find the bank for that BIC")

      expect(result).to eq(:invalid_bank_account)
      expect(ErrorNotifier).not_to have_received(:notify)
      expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).count).to eq(1)
      expect(payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).last.json_data["bank_account_id"]).to eq(bank_account.id)
    end

    it "names the row the sync submitted even when the seller replaces it mid-sync" do
      # The reason the row is passed down rather than re-read. Stripe's call is over the network,
      # so the seller can save replacement details before the rejection lands; a re-read would
      # then stamp the note with the replacement and blame details Stripe never saw.
      replacement = nil
      allow(Stripe::Account).to receive(:update) do
        bank_account.mark_deleted!
        replacement = create(:ach_account, user: user.reload)
        raise Stripe::InvalidRequestError.new("We couldn't find the bank for that BIC", "bank_account[routing_number]")
      end

      described_class.update_bank_account(user, passphrase:)

      note = payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).last
      expect(note.json_data["bank_account_id"]).to eq(bank_account.id)
      expect(note.json_data["bank_account_id"]).to_not eq(replacement.id)
    end
  end

  describe "bank account refused outright during a bank account sync" do
    let(:zip_code) { "94107" }
    let(:error_message) do
      "This bank account can't be used because previous payments or payouts failed. Contact support at https://support.stripe.com/contact if you think this is an error."
    end

    before do
      described_class.create_account(user, passphrase:)
      user.reload
      merchant_id = user.stripe_account.charge_processor_merchant_id
      allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(
        Stripe::Account.construct_from(id: merchant_id, metadata: {}, external_accounts: { object: "list", data: [] })
      )
      allow(Stripe::Account).to receive(:update).and_raise(
        Stripe::InvalidRequestError.new(error_message, "bank_account", code: "bank_account_unusable")
      )
    end

    it "tells the mailer this is a terminal rejection so the seller is asked for a different account" do
      result = nil
      expect do
        result = described_class.update_bank_account(user, passphrase:)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
        .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL, error_message)

      expect(result).to eq(:invalid_bank_account)
    end

    it "records the error details and marks the note so the retry loop knows the seller was told" do
      described_class.update_bank_account(user, passphrase:)

      note = payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).last
      expect(note.json_data["stripe_error_code"]).to eq("bank_account_unusable")
      expect(note.json_data["bank_account_id"]).to eq(bank_account.id)
      expect(described_class.bank_details_terminal_rejection_note?(note)).to be(true)
      expect(described_class.bank_details_format_rejection_note?(note)).to be(false)
      expect(note.json_data["seller_notified"]).to be(true)
    end
  end

  describe "classifying a bank rejection" do
    let(:zip_code) { "94107" }

    def error_for(message, code: nil)
      Stripe::InvalidRequestError.new(message, "bank_account", code:)
    end

    it "calls a previously-failed account terminal, not a format problem" do
      error = error_for("This bank account can't be used because previous payments or payouts failed.", code: "bank_account_unusable")

      expect(described_class.bank_details_terminal_rejection?(error)).to be(true)
      expect(described_class.bank_details_format_rejection?(error)).to be(false)
      expect(described_class.bank_rejection_kind_for(error)).to eq(StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL)
    end

    it "calls a bank outside payout coverage terminal even with no error code" do
      error = error_for("Stripe is unable to support this bank at this time.")

      expect(described_class.bank_details_terminal_rejection?(error)).to be(true)
      expect(described_class.bank_rejection_kind_for(error)).to eq(StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL)
    end

    it "prefers terminal over format when Stripe reuses a format code for a refused account" do
      error = error_for("Invalid account number: previous attempts to deliver payouts to this account failed.", code: "account_number_invalid")

      expect(described_class.bank_details_terminal_rejection?(error)).to be(true)
      expect(described_class.bank_details_format_rejection?(error)).to be(false)
      expect(described_class.bank_rejection_kind_for(error)).to eq(StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL)
    end

    it "still calls a plain mistyped code a format rejection" do
      error = error_for("Invalid routing number for PK.", code: "routing_number_invalid")

      expect(described_class.bank_details_terminal_rejection?(error)).to be(false)
      expect(described_class.bank_rejection_kind_for(error)).to eq(StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT)
    end

    it "leaves a directory miss unclassified so the wait-and-re-check copy is used" do
      error = error_for("We couldn't find the bank for that BIC")

      expect(described_class.bank_details_terminal_rejection?(error)).to be(false)
      expect(described_class.bank_details_format_rejection?(error)).to be(false)
      expect(described_class.bank_rejection_kind_for(error)).to be_nil
    end

    it "classifies an old note that carries only the human-readable content" do
      note = double(json_data: {}, content: "Stripe bank sync failed: bank_account_unusable — This bank account can't be used because previous payments or payouts failed.")

      expect(described_class.bank_details_terminal_rejection_note?(note)).to be(true)
      expect(described_class.bank_details_format_rejection_note?(note)).to be(false)
    end
  end

  describe "naming the value a directory miss refused" do
    let(:zip_code) { "94107" }

    def error_for(message, code: nil)
      Stripe::InvalidRequestError.new(message, "bank_account[routing_number]", code:)
    end

    let(:uz_bank_account) { build(:uzbekistan_bank_account, bank_code: "JSCLUZ22XXX", branch_code: "00401") }

    it "recognises a directory miss separately from format and terminal rejections" do
      error = error_for("We couldn't find the bank for that bank/branch code")

      expect(described_class.bank_details_directory_miss?(error)).to be(true)
      expect(described_class.bank_details_format_rejection?(error)).to be(false)
      expect(described_class.bank_details_terminal_rejection?(error)).to be(false)
    end

    it "does not call a mistyped code a directory miss" do
      expect(described_class.bank_details_directory_miss?(error_for("Invalid routing number for PK.", code: "routing_number_invalid"))).to be(false)
    end

    it "quotes back both halves and points at the branch code when the country collects two" do
      detail = described_class.bank_directory_miss_detail(uz_bank_account)

      expect(detail).to include("bank code JSCLUZ22XXX and branch code 00401")
      expect(detail).to include("branch code is the half")
      expect(detail).to include("head-office code")
    end

    it "quotes back the single value without the branch-code advice when there is only one" do
      detail = described_class.bank_directory_miss_detail(build(:ach_account, routing_number: "110000000"))

      expect(detail).to eq("The details we sent were routing number 110000000.")
    end

    it "returns nothing when there is no bank account to describe" do
      expect(described_class.bank_directory_miss_detail(nil)).to be_nil
    end

    it "builds a seller message that names the value, the field and what to do" do
      message = described_class.bank_directory_miss_seller_message(
        error_for("We couldn't find the bank for that bank/branch code"), uz_bank_account
      )

      expect(message).to start_with("Our payment partner couldn't match your bank details against its records.")
      expect(message).to include("bank code JSCLUZ22XXX and branch code 00401")
      expect(message).to include("up to #{RetryStripeRejectedPayoutSetupsJob::RETRY_WINDOW_WEEKS} weeks")
    end

    it "declines to speak for a rejection that is not a directory miss, so Stripe's own message survives" do
      expect(
        described_class.bank_directory_miss_seller_message(
          error_for("Invalid routing number for PK.", code: "routing_number_invalid"), uz_bank_account
        )
      ).to be_nil
    end
  end

  describe "bank code rejected on format during a bank account sync" do
    let(:zip_code) { "94107" }
    let(:error_message) do
      "Invalid routing number for PK. The number must contain both the bank code and the branch code, and should be in the format AAAAPKBB or AAAAPKBBXYZ."
    end

    before do
      described_class.create_account(user, passphrase:)
      user.reload
      merchant_id = user.stripe_account.charge_processor_merchant_id
      allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(
        Stripe::Account.construct_from(id: merchant_id, metadata: {}, external_accounts: { object: "list", data: [] })
      )
      allow(Stripe::Account).to receive(:update).and_raise(
        Stripe::InvalidRequestError.new(error_message, "bank_account[routing_number]", code: "routing_number_invalid")
      )
    end

    it "tells the mailer this is a format rejection and passes Stripe's expected-format message" do
      result = nil
      expect do
        result = described_class.update_bank_account(user, passphrase:)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
        .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT, error_message)

      expect(result).to eq(:invalid_bank_account)
    end

    it "records the error details and marks the note so the retry loop knows the seller was told" do
      described_class.update_bank_account(user, passphrase:)

      note = payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).last
      expect(note.json_data["stripe_error_code"]).to eq("routing_number_invalid")
      expect(note.json_data["stripe_error_message"]).to eq(error_message)
      expect(note.json_data["bank_account_id"]).to eq(bank_account.id)
      expect(note.json_data["seller_notified"]).to be(true)
    end
  end

  describe "block-listed external account during a bank account sync" do
    let(:zip_code) { "94107" }
    let(:error_message) do
      "You cannot use this external account because it is on your block list. Please contact us via https://support.stripe.com/contact if you think this is an error."
    end

    before do
      described_class.create_account(user, passphrase:)
      user.reload
      merchant_id = user.stripe_account.charge_processor_merchant_id
      allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(
        Stripe::Account.construct_from(id: merchant_id, metadata: {}, external_accounts: { object: "list", data: [] })
      )
      # The real error carries neither a code nor a param, which is why the classification has
      # to match on the message.
      allow(Stripe::Account).to receive(:update).and_raise(
        Stripe::InvalidRequestError.new(error_message, nil)
      )
    end

    it "tells the mailer this is a block, not a format rejection, so the seller is asked for a different account" do
      result = nil
      expect do
        result = described_class.update_bank_account(user, passphrase:)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
        .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_BLOCKED, error_message)

      expect(result).to eq(:invalid_bank_account)
    end

    it "treats the rejection as expected seller-input without paging Sentry" do
      allow(ErrorNotifier).to receive(:notify)

      described_class.update_bank_account(user, passphrase:)

      expect(ErrorNotifier).not_to have_received(:notify)
    end

    it "records the error details and marks the note so the retry loop knows the seller was told" do
      described_class.update_bank_account(user, passphrase:)

      note = payout_notes(StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX).last
      expect(note.json_data["stripe_error_message"]).to eq(error_message)
      expect(note.json_data["bank_account_id"]).to eq(bank_account.id)
      expect(note.json_data["seller_notified"]).to be(true)
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

  describe "platform-blocked account stays out of the retry loop" do
    let(:zip_code) { "94107" }

    before do
      described_class.create_account(user, passphrase:)
      user.reload
      merchant_id = user.stripe_account.charge_processor_merchant_id
      allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(
        Stripe::Account.construct_from(id: merchant_id, metadata: {}, external_accounts: { object: "list", data: [] })
      )
      allow(Stripe::Account).to receive(:update).and_raise(
        Stripe::InvalidRequestError.new(
          "Gumroad has blocked payments on this account. If you believe this is in error, please reach out to the platform for assistance.",
          nil
        )
      )
    end

    it "returns :account_blocked_by_platform without paging Sentry, emailing, or leaving a failure note" do
      expect(ErrorNotifier).not_to receive(:notify)

      result = nil
      expect do
        result = described_class.update_bank_account(user, passphrase:)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)

      expect(result).to eq(:account_blocked_by_platform)
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
