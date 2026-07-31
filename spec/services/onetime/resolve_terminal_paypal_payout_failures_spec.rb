# frozen_string_literal: true

require "spec_helper"

describe Onetime::ResolveTerminalPaypalPayoutFailures do
  describe ".process" do
    let(:seller) { create(:user, payment_address: "stuck@example.com") }

    def terminal_failure_for(user, reason: "PAYPAL 3148", created_at: 2.weeks.ago, payment_address: nil)
      create(:payment_failed, user:, payment_address: payment_address || user.payment_address,
                              failure_reason: reason, created_at:,
                              txn_id: nil, processor_fee_cents: nil)
    end

    # Gumroad only offers bank payouts in some countries, and the note has to say so — most sellers
    # who hit these rejections are in PayPal-only countries.
    def allow_bank_payouts_for(user)
      create(:user_compliance_info, user:, country: "United States")
    end

    # The explanation is the seller-visible note. Invalidating the address writes an internal note
    # too, so counting every payout_note row would conflate the two and let a missing explanation
    # pass because the invalidation happened to write something.
    def seller_visible_notes(user)
      user.reload.comments.with_type_payout_note.select { |note| PayoutNoteVisibility.seller_visible?(note) }
    end

    def seller_visible_note_count(user)
      seller_visible_notes(user).count
    end

    def latest_seller_visible_note(user)
      seller_visible_notes(user).last
    end

    it "writes a seller-visible note explaining the stopped payouts" do
      allow_bank_payouts_for(seller)
      payment = terminal_failure_for(seller)

      expect do
        described_class.process(dry_run: false)
      end.to change { seller_visible_note_count(seller) }.from(0).to(1)

      note = latest_seller_visible_note(seller)
      expect(note.content).to include("payments cannot be received in the country on that account's address")
      expect(note.content).to include("We've removed that PayPal account from your payout settings")
      expect(note.content).to include("Add a bank account there instead")
      expect(note.content).to include(payment.created_at.to_fs(:formatted_date_full_month))
      expect(PayoutNoteVisibility.seller_visible?(note)).to eq(true)
    end

    it "does not tell a seller in a PayPal-only country to add a bank account" do
      create(:user_compliance_info, user: seller, country: "Ukraine")
      terminal_failure_for(seller)

      described_class.process(dry_run: false)

      note = latest_seller_visible_note(seller)
      expect(note.content).to include("PayPal is the only payout method we can offer in your country")
      expect(note.content).to_not include("Add a bank account")
    end

    it "explains the currency restriction for a currency rejection" do
      terminal_failure_for(seller, reason: "PAYPAL 14159")

      described_class.process(dry_run: false)

      expect(latest_seller_visible_note(seller).content)
        .to include("your PayPal account cannot receive US dollars")
    end

    # The seller can clear a currency rejection on the account they already use, and we keep paying
    # them meanwhile, so the note must offer that fix and must not claim the retries stopped.
    # Reviewer finding on #6526.
    it "offers the in-place currency fix for a currency rejection" do
      allow_bank_payouts_for(seller)
      terminal_failure_for(seller, reason: "PAYPAL 14159")

      described_class.process(dry_run: false)

      content = latest_seller_visible_note(seller).content
      expect(content).to include("Sign in to PayPal and add US dollars to the currencies your account can receive")
      expect(content).to_not include("stopped retrying")
    end

    it "asks a seller whose account is also on hold to reply, rather than promising a payout date" do
      terminal_failure_for(seller)
      seller.update!(payouts_paused_internally: true)

      described_class.process(dry_run: false)

      note = latest_seller_visible_note(seller)
      expect(note.content).to include("Payouts on your account are also on hold")
      expect(note.content).to_not include("next payout date")
    end

    # A payout note is not something a seller can reply to — only the email is.
    it "sends a seller on hold to support rather than telling them to reply to the note" do
      terminal_failure_for(seller)
      seller.update!(payouts_paused_internally: true)

      described_class.process(dry_run: false)

      note = latest_seller_visible_note(seller)
      expect(note.content).to include("contact support")
      expect(note.content).to_not include("reply to this message")
    end

    # The payout gate checks the broader payouts_paused?, so a self-paused seller is skipped as
    # well — the plain "next payout date" promise on its own would not come true for them.
    it "names their own pause for a seller who paused their payouts themselves" do
      terminal_failure_for(seller)
      seller.update!(payouts_paused_by_user: true)

      described_class.process(dry_run: false)

      note = latest_seller_visible_note(seller)
      expect(note.content).to include("paused in your settings")
      expect(note.content).to include("resume payouts there")
      expect(note.content).to_not include("contact support")
    end

    # Newest wins among rejections that agree with each other — the seller should read the date of
    # the payout that actually stopped, not one from months ago. When the codes DISAGREE about
    # whether retries continue, the still-blocking one wins instead; see the example further down.
    it "describes the most recent rejection when the seller has several of the same kind" do
      terminal_failure_for(seller, created_at: 10.weeks.ago)
      latest = terminal_failure_for(seller, created_at: 1.week.ago)

      described_class.process(dry_run: false)

      expect(latest_seller_visible_note(seller).content)
        .to include("payments cannot be received in the country on that account's address")
        .and include(latest.created_at.to_fs(:formatted_date_full_month))
    end

    # The note quotes a date and a restriction, and the block is keyed on the address the seller
    # uses now — so a newer rejection against an address they have since abandoned must not be the
    # one described, or the seller reads about a payout to an old address and the wrong restriction.
    it "describes the rejection for the address the seller is stuck on, not a newer one for an old address" do
      stuck = terminal_failure_for(seller, created_at: 6.weeks.ago)
      create(:payment_failed, user: seller, payment_address: "old@example.com",
                              failure_reason: "PAYPAL 14159", created_at: 1.week.ago,
                              txn_id: nil, processor_fee_cents: nil)

      described_class.process(dry_run: false)

      note = latest_seller_visible_note(seller)
      expect(note.content).to include("payments cannot be received in the country on that account's address")
      expect(note.content).to include(stuck.created_at.to_fs(:formatted_date_full_month))
      expect(note.content).to_not include("cannot receive US dollars")
    end

    # The live block refuses a payout on a terminal rejection of any age, so an old rejection that
    # is still blocking has to be explained too — otherwise the oldest cases stay silent forever,
    # which is the whole failure this task exists to end.
    it "explains a rejection that is years old but still blocking" do
      terminal_failure_for(seller, created_at: 3.years.ago)

      expect do
        described_class.process(dry_run: false)
      end.to change { seller_visible_note_count(seller) }.from(0).to(1)
    end

    it "does not write a second note when run again" do
      terminal_failure_for(seller)
      described_class.process(dry_run: false)

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    # A note about the address they walked away from is not an explanation of the block they are
    # under now: it names a different date, and possibly the other of the two PayPal restrictions.
    it "explains the current block even when an older address was already explained" do
      terminal_failure_for(seller, reason: "PAYPAL 3148", created_at: 10.weeks.ago)
      described_class.process(dry_run: false)
      expect(seller_visible_note_count(seller)).to eq(1)

      seller.update!(payment_address: "current@example.com")
      current = terminal_failure_for(seller, reason: "PAYPAL 14159", created_at: 1.week.ago)

      expect do
        described_class.process(dry_run: false)
      end.to change { seller_visible_note_count(seller) }.from(1).to(2)

      expect(latest_seller_visible_note(seller).content)
        .to include("your PayPal account cannot receive US dollars")
        .and include(current.created_at.to_fs(:formatted_date_full_month))
    end

    # The backfill has to name the same blocker the weekly payout run does. On an address carrying
    # both codes the 3148 keeps stopping the money whichever came last, so a newer 14159 must not
    # be what the seller is sent to fix. Reviewer finding on #6526.
    it "explains the rejection still blocking payouts rather than the newest one" do
      allow_bank_payouts_for(seller)
      blocking = terminal_failure_for(seller, reason: "PAYPAL 3148", created_at: 6.weeks.ago)
      terminal_failure_for(seller, reason: "PAYPAL 14159", created_at: 1.week.ago)

      described_class.process(dry_run: false)

      expect(latest_seller_visible_note(seller).content)
        .to eq(blocking.terminal_paypal_failure_seller_note)
        .and include("payments cannot be received in the country on that account's address")
    end

    it "skips a seller who has since switched to a bank account" do
      terminal_failure_for(seller)
      create(:ach_account, user: seller)
      seller.update!(payment_address: "")

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    # Adding a bank account usually clears the payment address, but a seller who connected PayPal
    # through OAuth still has a payout email afterwards — so the address-keyed block check alone
    # would keep treating them as stuck and tell them their payouts had stopped.
    it "skips a seller who added a bank account while keeping a connected PayPal account" do
      terminal_failure_for(seller)
      create(:ach_account, user: seller)

      expect(seller.reload.paypal_payout_email).to be_present

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    # Stripe payouts carry no payment_address, so they never clear the address-keyed block. A seller
    # who moved to Stripe Connect is being paid every week, and would otherwise be told the opposite.
    it "skips a seller who has since moved to Stripe Connect" do
      terminal_failure_for(seller)
      create(:merchant_account_stripe_connect, user: seller)
      seller.update!(check_merchant_account_is_linked: true)

      expect(seller.reload.has_stripe_account_connected?).to eq(true)

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    # Suspension is checked before the payout method is even looked at, so promising this seller a
    # payout once they fix their PayPal account would be false.
    it "skips a suspended seller" do
      terminal_failure_for(seller)
      seller.flag_for_fraud!(author_id: seller.id)
      seller.suspend_for_fraud!(author_id: seller.id)

      expect(seller.reload).to be_suspended

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    # A closed account is paused internally and will not be paid whatever the seller does, so the
    # "reply and we'll review the hold" copy would send them to support for nothing.
    it "skips a closed account" do
      terminal_failure_for(seller)
      seller.update!(deleted_at: Time.current)

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    it "skips a seller who has since changed their PayPal address" do
      terminal_failure_for(seller)
      seller.update!(payment_address: "working@example.com")

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    it "skips a seller who has been paid out since the rejection" do
      terminal_failure_for(seller, created_at: 4.weeks.ago)
      create(:payment_completed, user: seller, payment_address: seller.payment_address, created_at: 1.week.ago)

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    it "ignores retryable rejections" do
      terminal_failure_for(seller, reason: "PAYPAL 3015")

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller_visible_note_count(seller) }
    end

    # A currency rejection is explained but still retried, so nothing this task writes may claim
    # the payouts have stopped. Reviewer finding on #6526: the eligibility check deliberately uses
    # the wider EXPLAINED set rather than the retry-blocking one, and that is only defensible while
    # the copy it produces describes a failing payout rather than a block.
    it "does not tell a currency-rejected seller their payouts have been stopped" do
      allow_bank_payouts_for(seller)
      terminal_failure_for(seller, reason: "PAYPAL 14159")

      described_class.process(dry_run: false)

      content = latest_seller_visible_note(seller).content
      expect(content).to include("PayPal will not send your payout")
      expect(content).to_not include("stopped retrying")
      expect(content).to_not include("we have stopped")
      # The retries continue, so the plain next-payout-date promise is the true one for them.
      expect(content).to include("will be paid out on the next payout date")
    end

    # The one seller for whom this task is the ONLY path to an explanation, and the reason its
    # eligibility check cannot be narrowed to the retry-blocking set. Reviewer finding on #6526.
    #
    # A self-paused seller with a currency rejection is skipped by Payouts.is_user_payable at the
    # payouts_paused? gate, so no further payout ever fails and the failure-time note never fires;
    # and the live re-explain inside that gate is scoped to payouts_paused_internally?, so it
    # excludes them too. Narrowing this task to RETRY_BLOCKING would leave them reading "payouts
    # were paused" with nothing naming PayPal — the gumroad-private#1478 dead end, kept alive for
    # exactly the sellers whose payouts keep failing every week.
    it "explains a currency rejection to a self-paused seller no other path reaches" do
      allow_bank_payouts_for(seller)
      payment = terminal_failure_for(seller, reason: "PAYPAL 14159")
      seller.update!(payouts_paused_by_user: true)

      expect(PaypalPayoutProcessor.terminal_failure_blocking_payouts?(seller.reload)).to eq(false)

      expect do
        described_class.process(dry_run: false)
      end.to change { seller_visible_note_count(seller) }.from(0).to(1)

      content = latest_seller_visible_note(seller).content
      expect(content).to include("your PayPal account cannot receive US dollars")
      expect(content).to include(payment.created_at.to_fs(:formatted_date_full_month))
      # Their own switch is what holds the money once PayPal is fixed, so the copy names it rather
      # than promising a payout date their pause prevents.
      expect(content).to include("paused in your settings")
    end

    # ── Invalidate and notify (Sahil's ruling on gumroad-private#1478) ──────────────────────────

    # The point of invalidating: the settings page stops offering a payout method we will never pay
    # to, which is what the note tells the seller to change.
    it "removes the refused PayPal address from the account" do
      terminal_failure_for(seller)

      described_class.process(dry_run: false)

      expect(seller.reload.payment_address).to be_blank
      expect(seller.invalidated_paypal_payout_address).to eq("stuck@example.com")
    end

    # Clearing the address is what every rejection lookup is keyed on, so getting this wrong would
    # quietly release the block and erase the seller's explanation along with it.
    it "keeps the seller blocked and explained after the address is removed" do
      terminal_failure_for(seller)

      described_class.process(dry_run: false)

      expect(PaypalPayoutProcessor.terminal_failure_blocking_payouts?(seller.reload)).to eq(true)
      expect(PaypalPayoutProcessor.rejection_to_explain(seller)).to be_present
      expect(Payouts.is_user_payable(seller, Date.current)).to eq(false)
    end

    # A currency rejection is repairable on the account the seller already has and we keep retrying
    # it, so taking the address away would remove a payout method that is about to start working.
    it "does not remove the address for a currency rejection" do
      terminal_failure_for(seller, reason: "PAYPAL 14159")

      described_class.process(dry_run: false)

      expect(seller.reload.payment_address).to eq("stuck@example.com")
      expect(seller.invalidated_paypal_payout_address).to be_blank
    end

    it "notifies the seller" do
      terminal_failure_for(seller)

      expect do
        described_class.process(dry_run: false)
      end.to have_enqueued_mail(ContactingCreatorMailer, :paypal_payout_permanently_failed)
    end

    # The 383 sellers this send exists for are all dropped at gates that sit earlier than the PayPal
    # processor, so if either gate suppressed the email here nobody would be told at all.
    it "notifies a seller whose payouts are on hold" do
      terminal_failure_for(seller)
      seller.update!(payouts_paused_internally: true)

      expect do
        described_class.process(dry_run: false)
      end.to have_enqueued_mail(ContactingCreatorMailer, :paypal_payout_permanently_failed)
    end

    it "notifies a seller whose balance is below the payout minimum" do
      terminal_failure_for(seller)
      allow_any_instance_of(User).to receive(:unpaid_balance_cents_up_to_date).and_return(500)

      expect do
        described_class.process(dry_run: false)
      end.to have_enqueued_mail(ContactingCreatorMailer, :paypal_payout_permanently_failed)
    end

    it "does not email the same seller twice across runs" do
      terminal_failure_for(seller)
      described_class.process(dry_run: false)

      expect do
        described_class.process(dry_run: false)
      end.to_not have_enqueued_mail(ContactingCreatorMailer, :paypal_payout_permanently_failed)
    end

    # The weekly run already emailed this one seller of the 384; a second copy would be noise.
    it "does not email a seller the live payout path already emailed" do
      terminal_failure_for(seller)
      seller.update!(payout_date_of_last_paypal_terminal_failure_email: Date.current.to_s)

      expect do
        described_class.process(dry_run: false)
      end.to_not have_enqueued_mail(ContactingCreatorMailer, :paypal_payout_permanently_failed)
    end

    # Everything the seller reads describes the removal, so the removal has to have happened before
    # the copy is generated — otherwise the first note and the first email deny it.
    it "writes copy that matches the account state it just changed" do
      allow_bank_payouts_for(seller)
      terminal_failure_for(seller)

      described_class.process(dry_run: false)

      expect(latest_seller_visible_note(seller).content)
        .to include("We've removed that PayPal account from your payout settings")
    end

    # A seller paid through a connected PayPal account has no saved address to remove, so claiming we
    # removed one would be false.
    it "does not claim a removal for a seller paid through a connected PayPal account" do
      allow_bank_payouts_for(seller)
      terminal_failure_for(seller, payment_address: "connected@example.com")
      create(:merchant_account_paypal, user: seller)
      allow_any_instance_of(MerchantAccount).to receive(:paypal_account_details)
        .and_return("primary_email" => "connected@example.com")
      seller.update!(payment_address: "")

      expect(seller.reload.paypal_payout_email).to eq("connected@example.com")

      described_class.process(dry_run: false)

      content = latest_seller_visible_note(seller).content
      expect(content).to_not include("We've removed")
      expect(content).to include("connect a PayPal account registered in a country that can receive PayPal payments")
    end

    it "writes nothing on a dry run" do
      terminal_failure_for(seller)

      expect do
        expect(described_class.process(dry_run: true)).to eq(noted: 1, emailed: 1, invalidated: 1, skipped: 0)
      end.to_not change { seller_visible_note_count(seller) }
      expect(seller.reload.payment_address).to eq("stuck@example.com")
    end

    # Writing seller-visible notes to the whole population must be asked for, not the accident of
    # typing the shortest thing that runs. Reviewer finding on #6526.
    it "reports without writing when no dry_run is given" do
      terminal_failure_for(seller)

      expect do
        expect(described_class.process).to eq(noted: 1, emailed: 1, invalidated: 1, skipped: 0)
      end.to_not change { seller_visible_note_count(seller) }
    end

    it "reports without writing when the instance method is called with no dry_run" do
      terminal_failure_for(seller)

      expect do
        described_class.new.process
      end.to_not change { seller_visible_note_count(seller) }
    end
  end
end
