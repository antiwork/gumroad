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
        .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT, note.content, nil)

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

    it "keeps the notification marker when the abandonment fails, so the retry cannot re-email" do
      # The abandonment can fail (and roll back) after the seller has already been emailed. The
      # note then stays outstanding and every later weekly pass reaches this branch again — so if
      # the marker rolled back with the abandonment, each of those passes would send the seller
      # another copy of the same email. Simulate the failure by making the audit note raise.
      note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — Invalid routing number for PK. Should be in the format AAAAPKBB.")
      allow(User).to receive(:find_by).with(id: user.id).and_return(user)
      allow(user).to receive(:add_payout_note).and_call_original
      allow(user).to receive(:add_payout_note).with(content: described_class::BANK_FORMAT_REJECTION_NOTE, seller_visible: false).and_raise(ActiveRecord::RecordInvalid.new(Comment.new))

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account).once

      note.reload
      expect(note.json_data["abandoned_at"]).to be_blank
      expect(note.json_data["seller_notified"]).to be(true)

      # The next pass redoes the abandonment it could not finish, in silence.
      expect do
        described_class.new.perform(user.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
    end

    it "re-sends on a later pass when the notification enqueue itself fails" do
      # The marker is claimed before the email is enqueued, so a failed enqueue must release it
      # again — otherwise the note carries a claim for a message that was never sent and the
      # seller is abandoned in silence.
      note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — Invalid routing number for PK. Should be in the format AAAAPKBB.")
      mail = double("mail")
      allow(mail).to receive(:deliver_later).and_raise(Redis::CannotConnectError)
      allow(ContactingCreatorMailer).to receive(:invalid_bank_account).and_return(mail)

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["seller_notified"]).to be_blank
      expect(note.json_data["abandoned_at"]).to be_blank

      # The next pass finds the note untouched and sends for real.
      allow(ContactingCreatorMailer).to receive(:invalid_bank_account).and_call_original
      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account).once
      expect(note.reload.json_data["seller_notified"]).to be(true)
    end

    it "sends on a later pass when a run was killed after claiming the send but before enqueueing" do
      # A hard kill (Sidekiq shutdown, OOM) between the claim commit and the enqueue leaves the
      # claim behind with nothing to release it. The claim has to expire, otherwise the seller is
      # abandoned holding a bank code they were never told to correct.
      note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — Invalid routing number for PK. Should be in the format AAAAPKBB.")
      note.json_data["seller_notified_claimed_at"] = (described_class::NOTIFICATION_CLAIM_TTL + 1.minute).ago.iso8601
      note.save!

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account).once

      note.reload
      expect(note.json_data["seller_notified"]).to be(true)
      expect(note.json_data["seller_notified_claimed_at"]).to be_blank
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_FORMAT_REJECTION)
    end

    it "leaves the note outstanding while another run holds a fresh send claim" do
      # Two runs overlapping must not both email the seller, and the one that loses the race must
      # not abandon the note either — the winner may still fail, and abandoning is terminal.
      note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — Invalid routing number for PK. Should be in the format AAAAPKBB.")
      note.json_data["seller_notified_claimed_at"] = 1.minute.ago.iso8601
      note.save!

      expect do
        described_class.new.perform(user.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)

      expect(note.reload.json_data["abandoned_at"]).to be_blank
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

  describe "external account block-listed by Stripe" do
    let!(:merchant_account) { create(:merchant_account, user:) }
    let(:blocked_message) do
      "You cannot use this external account because it is on your block list. Please contact us via https://support.stripe.com/contact if you think this is an error."
    end

    def add_blocked_note(notified: true)
      note = user.add_payout_note(content: "#{bank_prefix}: unknown — #{blocked_message}")
      note.json_data["stripe_error_code"] = nil
      note.json_data["stripe_error_message"] = blocked_message
      note.json_data["seller_notified"] = true if notified
      note.save!
      note
    end

    it "stops retrying instead of re-sending an account Stripe will always refuse" do
      # This is the whole defect: the account details are valid, so nothing about re-sending them
      # can change the answer. Before this the note fell through to the generic retry path and
      # burned the full weekly window, while the seller was told to wait (gumroad-private#1476).
      note = add_blocked_note
      expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["abandoned_at"]).to be_present
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_ACCOUNT_BLOCKED)
      expect(note.json_data["retry_count"]).to be_nil
      expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::BANK_ACCOUNT_BLOCKED_NOTE)
    end

    it "emails the seller the add-a-different-account instruction, not the correct-your-code one" do
      # The rejection_kind is the load-bearing part: with BANK_REJECTION_KIND_FORMAT the seller is
      # told to re-enter details they already entered correctly, which is the advice that produced
      # a three-month loop.
      note = add_blocked_note(notified: false)

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
        .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_BLOCKED, blocked_message, nil)

      note.reload
      expect(note.json_data["seller_notified"]).to be(true)
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_ACCOUNT_BLOCKED)
    end

    it "recognises the block from an older note that carries only the human-readable content" do
      # Notes written before the structured stripe_error_message field existed only have the note
      # text, so the classifier has to fall back to sniffing it — same as the format one.
      note = user.add_payout_note(content: "#{bank_prefix}: unknown — #{blocked_message}")
      note.json_data["seller_notified"] = true
      note.save!
      expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)

      described_class.new.perform(user.id)

      expect(note.reload.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_ACCOUNT_BLOCKED)
    end

    it "still classifies a format rejection as a format rejection" do
      # The three unfixable branches sit next to each other and all abandon, so a spec that only
      # checked "was abandoned" would pass even if the block branch swallowed format rejections
      # and sent them the wrong email. Pin the reason.
      note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — Invalid routing number for PK. Should be in the format AAAAPKBB.")
      note.json_data["seller_notified"] = true
      note.save!

      described_class.new.perform(user.id)

      expect(note.reload.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_FORMAT_REJECTION)
    end
  end

  describe "bank account refused outright by Stripe" do
    let!(:merchant_account) { create(:merchant_account, user:) }
    let(:unusable_message) do
      "This bank account can't be used because previous payments or payouts failed."
    end

    def add_terminal_rejection_note(notified: true)
      note = user.add_payout_note(content: "#{bank_prefix}: bank_account_unusable — #{unusable_message}")
      note.json_data["stripe_error_code"] = "bank_account_unusable"
      note.json_data["stripe_error_message"] = unusable_message
      note.json_data["seller_notified"] = true if notified
      note.save!
      note
    end

    it "stops retrying instead of re-sending an account Stripe will never accept" do
      note = add_terminal_rejection_note
      expect(StripeMerchantAccountManager).not_to receive(:update_bank_account)

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["abandoned_at"]).to be_present
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_TERMINAL_REJECTION)
      expect(note.json_data["retry_count"]).to be_nil
      expect(user.comments.alive.with_type_payout_note.last.content).to eq(described_class::BANK_TERMINAL_REJECTION_NOTE)
    end

    it "does not email the seller that retries were exhausted" do
      # Seeded at the retry ceiling so that WITHOUT the early exit this note would fall through to
      # give_up!, which does send the exhausted email.
      note = add_terminal_rejection_note
      note.json_data["retry_count"] = RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES
      note.save!

      expect do
        described_class.new.perform(user.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted)

      expect(note.reload.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_TERMINAL_REJECTION)
    end

    it "emails the seller to use a different account before abandoning an unnotified note" do
      note = add_terminal_rejection_note(notified: false)

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :invalid_bank_account)
        .with(user.id, StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL, unusable_message, nil)

      note.reload
      expect(note.json_data["seller_notified"]).to be(true)
      expect(note.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_TERMINAL_REJECTION)
    end

    it "abandons a format note and a terminal note separately, each with its own audit note" do
      # A seller can accumulate both kinds. Sweeping them together would label half of them with
      # the wrong reason and tell the seller to fix a code when the account itself is refused.
      terminal_note = add_terminal_rejection_note
      format_note = user.add_payout_note(content: "#{bank_prefix}: routing_number_invalid — Invalid routing number for PK. Should be in the format AAAAPKBB.")
      format_note.json_data["seller_notified"] = true
      format_note.save!

      described_class.new.perform(user.id)
      described_class.new.perform(user.id)

      expect(terminal_note.reload.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_TERMINAL_REJECTION)
      expect(format_note.reload.json_data["abandoned_reason"]).to eq(described_class::ABANDONED_REASON_BANK_FORMAT_REJECTION)

      audit_notes = user.comments.alive.with_type_payout_note.map(&:content)
      expect(audit_notes).to include(described_class::BANK_TERMINAL_REJECTION_NOTE)
      expect(audit_notes).to include(described_class::BANK_FORMAT_REJECTION_NOTE)
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

    it "sends the exhausted notice even when recording the abandonment fails" do
      # Abandonment is terminal — an abandoned note is skipped by every later run — and this is
      # the only place the exhausted email is sent. So the email must not be downstream of a
      # write that can fail: if it were, a failure here would silently cost the seller the one
      # message telling them the automated retries stopped. Simulate that failure by making the
      # audit note inside the transaction raise.
      note = add_note(bank_prefix, json: { retry_count: RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES })
      allow(User).to receive(:find_by).with(id: user.id).and_return(user)
      allow(user).to receive(:add_payout_note).and_call_original
      allow(user).to receive(:add_payout_note).with(content: described_class::GAVE_UP_NOTE, seller_visible: false)
                                              .and_raise(ActiveRecord::RecordInvalid.new(Comment.new))

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted).with(user.id, "bank")

      # The abandonment rolled back with its audit note, so the note is still outstanding and the
      # next run retries the whole terminal step rather than leaving a dead record behind.
      expect(note.reload.json_data["abandoned_at"]).to be_blank
    end

    it "does not re-send the exhausted notice on the passes that retry a failed abandonment" do
      # A note left outstanding by a failed abandonment is still at the retry ceiling, so every
      # later weekly pass lands here again. Only the abandonment should be retried — the seller
      # has already been told the automated retries stopped, and telling them weekly is spam.
      note = add_note(bank_prefix, json: { retry_count: RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES })
      allow(User).to receive(:find_by).with(id: user.id).and_return(user)
      allow(user).to receive(:add_payout_note).and_call_original
      allow(user).to receive(:add_payout_note).with(content: described_class::GAVE_UP_NOTE, seller_visible: false)
                                              .and_raise(ActiveRecord::RecordInvalid.new(Comment.new))

      described_class.new.perform(user.id)
      expect(note.reload.json_data["abandoned_at"]).to be_blank

      expect do
        described_class.new.perform(user.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted)
    end

    it "re-sends the exhausted notice on a later pass when the enqueue itself fails" do
      # The marker is claimed before the enqueue, so a failed enqueue has to release it — a note
      # left claiming "we told them" for a message that never went out would be abandoned in
      # silence, which is the failure this notice exists to prevent.
      note = add_note(bank_prefix, json: { retry_count: RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES })
      mail = double("mail")
      allow(mail).to receive(:deliver_later).and_raise(Redis::CannotConnectError)
      allow(ContactingCreatorMailer).to receive(:payout_setup_retry_exhausted).and_return(mail)

      described_class.new.perform(user.id)

      note.reload
      expect(note.json_data["exhausted_notified"]).to be_blank
      expect(note.json_data["abandoned_at"]).to be_blank

      allow(ContactingCreatorMailer).to receive(:payout_setup_retry_exhausted).and_call_original
      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted).once
      expect(note.reload.json_data["abandoned_at"]).to be_present
    end

    it "sends the exhausted notice on a later pass when a run was killed mid-send" do
      # Same hard-kill window as the format-rejection path: the claim is left behind with nothing
      # to release it, so it has to expire rather than silence the notice for good.
      note = add_note(bank_prefix, json: {
                        retry_count: RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES,
                        exhausted_notified_claimed_at: (described_class::NOTIFICATION_CLAIM_TTL + 1.minute).ago.iso8601
                      })

      expect do
        described_class.new.perform(user.id)
      end.to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted).once

      note.reload
      expect(note.json_data["exhausted_notified"]).to be(true)
      expect(note.json_data["abandoned_at"]).to be_present
    end

    it "leaves the note outstanding while another run holds a fresh exhausted-notice claim" do
      note = add_note(bank_prefix, json: {
                        retry_count: RetryStripeRejectedPayoutSetupsJob::MAX_RETRIES,
                        exhausted_notified_claimed_at: 1.minute.ago.iso8601
                      })

      expect do
        described_class.new.perform(user.id)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :payout_setup_retry_exhausted)

      expect(note.reload.json_data["abandoned_at"]).to be_blank
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
