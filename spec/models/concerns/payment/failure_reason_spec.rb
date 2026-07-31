# frozen_string_literal: true

require "spec_helper"

describe Payment::FailureReason do
  let(:payment) { create(:payment) }

  # The payout walk looks the seller-facing wording up by rejection code while deciding whether to
  # explain the block, so a code treated as terminal without wording would raise inside the weekly
  # payout run. These hold that invariant, and the narrower one that matters more: refusing to
  # retry is a strictly stronger claim than explaining, so it must apply to strictly fewer codes.
  describe "TERMINAL_PAYPAL_FAILURE_REASONS" do
    it "explains both account-level rejections but only blocks retries on the unrepairable one" do
      expect(described_class::EXPLAINED_PAYPAL_FAILURE_REASONS).to match_array(["PAYPAL 3148", "PAYPAL 14159"])

      # 14159 — "your PayPal account cannot receive US dollars" — is explained but still retried,
      # because PayPal lets a recipient add receive currencies on the same account. The block is
      # keyed on the payout address, which does not change when they do that, so blocking would
      # freeze the balance of a seller who had already fixed it. See
      # RETRY_BLOCKING_PAYPAL_FAILURE_REASONS for what it would take to promote it.
      expect(described_class::RETRY_BLOCKING_PAYPAL_FAILURE_REASONS).to match_array(["PAYPAL 3148"])
      expect(described_class::RETRY_BLOCKING_PAYPAL_FAILURE_REASONS).not_to include("PAYPAL 14159")
    end

    it "never blocks retries on a rejection it cannot explain to the seller" do
      expect(described_class::RETRY_BLOCKING_PAYPAL_FAILURE_REASONS - described_class::EXPLAINED_PAYPAL_FAILURE_SELLER_REASONS.keys)
        .to be_empty
      expect(described_class::EXPLAINED_PAYPAL_FAILURE_REASONS)
        .to match_array(described_class::EXPLAINED_PAYPAL_FAILURE_SELLER_REASONS.keys)
    end

    # The in-place fix and the block are opposites: we only stop retrying because nothing the seller
    # does inside the account changes the answer. An overlap would send a seller to fix something
    # while an address-keyed block guaranteed we never noticed.
    it "never blocks retries on a rejection the seller can repair in place" do
      expect(described_class::REPAIRABLE_IN_PLACE_PAYPAL_FAILURE_REASONS).to match_array(["PAYPAL 14159"])
      expect(described_class::REPAIRABLE_IN_PLACE_PAYPAL_FAILURE_REASONS & described_class::RETRY_BLOCKING_PAYPAL_FAILURE_REASONS)
        .to be_empty
      expect(described_class::REPAIRABLE_IN_PLACE_PAYPAL_FAILURE_REASONS - described_class::EXPLAINED_PAYPAL_FAILURE_REASONS)
        .to be_empty
    end

    # Recognising an already-written note by its wording is how the pipeline knows whether the
    # seller can still see an explanation, so a reword has to keep matching the old rows.
    it "still recognises every wording ever shipped" do
      described_class::HISTORICAL_SELLER_REASONS.each_value do |reasons|
        reasons.each do |reason|
          expect(described_class.terminal_paypal_explanation_note?("Your payout could not be sent because #{reason}."))
            .to eq(true)
        end
      end
    end

    # Every code treated as terminal needs its own historical-wording entry, because the
    # per-rejection match below looks its restriction sentences up by code — a code missing from
    # the map would silently match nothing and the seller would get a duplicate note every run.
    it "records historical wording for every rejection it explains" do
      expect(described_class::HISTORICAL_SELLER_REASONS.keys)
        .to match_array(described_class::EXPLAINED_PAYPAL_FAILURE_REASONS)
    end

    it "does not recognise an unrelated payout note" do
      expect(described_class.terminal_paypal_explanation_note?("Payout on July 1st, 2026 was skipped because the account was under review."))
        .to eq(false)
      expect(described_class.terminal_paypal_explanation_note?(nil)).to eq(false)
    end
  end

  # Deciding whether the seller still needs telling is a narrower question than "carries some
  # terminal-PayPal explanation": a note about a rejection on a PayPal address they have since
  # replaced explains a block they are no longer under.
  describe ".terminal_paypal_explanation_note_for?" do
    let(:rejection) do
      create(:payment_failed, failure_reason: "PAYPAL 14159", created_at: 3.weeks.ago,
                              txn_id: nil, processor_fee_cents: nil)
    end

    it "recognises the note written for that rejection" do
      expect(described_class.terminal_paypal_explanation_note_for?(rejection.terminal_paypal_failure_seller_note, rejection))
        .to eq(true)
    end

    it "recognises a note written under an earlier wording of the same restriction" do
      historical = described_class::HISTORICAL_SELLER_REASONS.fetch("PAYPAL 14159").first
      note = "Your payout on #{rejection.created_at.to_fs(:formatted_date_full_month)} could not be sent " \
             "because #{historical}. Add a bank account in your payout settings."

      expect(described_class.terminal_paypal_explanation_note_for?(note, rejection)).to eq(true)
    end

    it "does not accept a note about a different rejection date" do
      other = create(:payment_failed, user: rejection.user, failure_reason: "PAYPAL 14159",
                                      created_at: 10.weeks.ago, txn_id: nil, processor_fee_cents: nil)

      expect(described_class.terminal_paypal_explanation_note_for?(other.terminal_paypal_failure_seller_note, rejection))
        .to eq(false)
    end

    it "does not accept a note about the other PayPal restriction" do
      other = create(:payment_failed, user: rejection.user, failure_reason: "PAYPAL 3148",
                                      created_at: rejection.created_at, txn_id: nil, processor_fee_cents: nil)

      expect(described_class.terminal_paypal_explanation_note_for?(other.terminal_paypal_failure_seller_note, rejection))
        .to eq(false)
    end

    it "does not accept a blank note" do
      expect(described_class.terminal_paypal_explanation_note_for?(nil, rejection)).to eq(false)
    end
  end

  describe "#add_payment_failure_reason_comment" do
    context "when failure_reason is not present" do
      it "doesn't add payout note to the user" do
        expect do
          payment.mark_failed!
        end.to_not change { payment.user.comments.count }
      end
    end

    context "when failure_reason is present" do
      context "when processor is PAYPAL" do
        context "when solution is present" do
          it "adds payout note to the user" do
            expect do
              payment.mark_failed!("PAYPAL 11711")
            end.to change { payment.user.comments.count }.by(1)

            payout_note = "Payout via Paypal on #{payment.created_at} failed because per-transaction sending limit exceeded. "
            payout_note += "Solution: Contact PayPal to get receiving limit on the account increased. "
            payout_note += "If that's not possible, Gumroad can split their payout, please contact Gumroad Support."
            expect(payment.user.comments.last.content).to eq payout_note
          end
        end

        context "when solution is not present" do
          it "doesn't add payout note to the user" do
            expect do
              payment.mark_failed!("PAYPAL unknown_failure_reason")
            end.to_not change { payment.user.comments.count }
          end
        end

        context "when the rejection is terminal" do
          before do
            # Gumroad supports bank payouts here, so the note may suggest one. Most sellers who hit
            # these rejections are in PayPal-only countries, covered separately below.
            create(:user_compliance_info, user: payment.user, country: "United States")
          end

          it "tells the seller PayPal will not send the payout and what to change" do
            expect do
              payment.mark_failed!("PAYPAL 3148")
            end.to change { payment.user.comments.count }.by(1)

            note = payment.user.comments.last
            expect(note.content).to eq(
              "Your payout on #{payment.created_at.to_fs(:formatted_date_full_month)} could not be sent because " \
              "PayPal will not send payouts to your PayPal account, because payments cannot be received in the country on that account's address. " \
              "Add a bank account in your payout settings, or use a different PayPal account that can receive US dollars. " \
              "Your balance is safe in the meantime and will be paid out on the next payout date after a working payout method is on file."
            )
            expect(PayoutNoteVisibility.seller_visible?(note)).to eq(true)
          end

          it "tells a seller whose account is also on hold to contact support instead of promising a date" do
            payment.user.update!(payouts_paused_internally: true)

            payment.mark_failed!("PAYPAL 3148")

            note = payment.user.comments.last
            expect(note.content).to include("Payouts on your account are also on hold")
            # A payout note is not repliable; only the email version says "reply to this email".
            expect(note.content).to include("contact support")
            expect(note.content).to_not include("reply to this message")
            expect(note.content).to_not include("next payout date")
            expect(note.content).to_not include("placed a hold")
            expect(PayoutNoteVisibility.seller_visible?(note)).to eq(true)
          end

          # The payout gate checks the broader payouts_paused?, so this seller is skipped as well —
          # the promise only comes true once they flip their own switch back, so the note says so.
          it "names their own pause for a seller who paused their own payouts" do
            payment.user.update!(payouts_paused_by_user: true)

            payment.mark_failed!("PAYPAL 3148")

            note = payment.user.comments.last
            expect(note.content).to include("paused in your settings")
            expect(note.content).to include("resume payouts there")
            expect(note.content).to include("next payout date")
            expect(note.content).to_not include("contact support")
          end

          # Both flags are independent, so the combined state is real: naming only the hold would
          # imply support can release the balance while the seller's own pause still blocks it.
          # Reviewer finding on #6526.
          it "names both pauses for a seller who is held and paused their own payouts" do
            payment.user.update!(payouts_paused_internally: true, payouts_paused_by_user: true)

            payment.mark_failed!("PAYPAL 3148")

            note = payment.user.comments.last
            expect(note.content).to include("also on hold, and paused in your settings")
            expect(note.content).to include("resume payouts in your settings")
            expect(note.content).to include("contact support")
            expect(note.content).to_not include("on the next payout date")
            expect(PayoutNoteVisibility.seller_visible?(note)).to eq(true)
          end

          it "names the currency restriction when PayPal cannot send US dollars to the account" do
            payment.mark_failed!("PAYPAL 14159")

            expect(payment.user.comments.last.content).to include(
              "your PayPal account cannot receive US dollars"
            )
          end

          it "does not tell a seller in a PayPal-only country to add a bank account" do
            payment.user.alive_user_compliance_info.mark_deleted!
            create(:user_compliance_info, user: payment.user, country: "Ukraine")

            payment.mark_failed!("PAYPAL 3148")

            note = payment.user.comments.last
            expect(note.content).to include("PayPal is the only payout method we can offer in your country")
            expect(note.content).to_not include("Add a bank account")
            expect(PayoutNoteVisibility.seller_visible?(note)).to eq(true)
          end
        end
      end

      context "when processor is Stripe" do
        before do
          payment.update!(processor: PayoutProcessorType::STRIPE)
        end

        context "when solution is present" do
          it "adds payout note to the user" do
            expect do
              payment.mark_failed!("account_closed")
            end.to change { payment.user.comments.count }.by(1)

            payout_note = "Payout via Stripe on #{payment.created_at} failed because the bank account has been closed. "
            payout_note += "Solution: Use another bank account."
            expect(payment.user.comments.last.content).to eq payout_note
          end
        end

        context "when failure reason is bank_account_not_found_at_stripe" do
          it "adds a payout note explaining the bank account needs to be re-added" do
            expect do
              payment.mark_failed!(Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
            end.to change { payment.user.comments.count }.by(1)

            payout_note = "Payout via Stripe on #{payment.created_at} failed because the bank account on file at Stripe was replaced, so payouts can no longer be sent to the saved reference. "
            payout_note += "Solution: Re-add the bank account in payout settings to refresh the saved reference."
            expect(payment.user.comments.last.content).to eq payout_note
          end
        end

        context "when failure reason is destination_currency_mismatch" do
          it "adds a payout note explaining the bank account currency mismatch" do
            expect do
              payment.mark_failed!(Payment::FailureReason::DESTINATION_CURRENCY_MISMATCH)
            end.to change { payment.user.comments.count }.by(1)

            payout_note = "Payout via Stripe on #{payment.created_at} failed because the payout currency does not match any bank account configured to receive it on the connected Stripe account. "
            payout_note += "Solution: Confirm a bank account that accepts this currency is set up in payout settings. If the issue persists, contact Gumroad Support."
            expect(payment.user.comments.last.content).to eq payout_note
          end
        end

        context "when solution is not present" do
          it "doesn't add payout note to the user" do
            expect do
              payment.mark_failed!("unknown_failure_reason")
            end.to_not change { payment.user.comments.count }
          end
        end
      end
    end
  end
end
