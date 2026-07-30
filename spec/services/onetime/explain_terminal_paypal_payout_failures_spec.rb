# frozen_string_literal: true

require "spec_helper"

describe Onetime::ExplainTerminalPaypalPayoutFailures do
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

    it "writes a seller-visible note explaining the stopped payouts" do
      allow_bank_payouts_for(seller)
      payment = terminal_failure_for(seller)

      expect do
        described_class.process(dry_run: false)
      end.to change { seller.comments.with_type_payout_note.count }.from(0).to(1)

      note = seller.comments.with_type_payout_note.last
      expect(note.content).to include("payments cannot be received in the country on that account's address")
      expect(note.content).to include("Add a bank account in your payout settings")
      expect(note.content).to include(payment.created_at.to_fs(:formatted_date_full_month))
      expect(PayoutNoteVisibility.seller_visible?(note)).to eq(true)
    end

    it "does not tell a seller in a PayPal-only country to add a bank account" do
      create(:user_compliance_info, user: seller, country: "Ukraine")
      terminal_failure_for(seller)

      described_class.process(dry_run: false)

      note = seller.comments.with_type_payout_note.last
      expect(note.content).to include("PayPal is the only payout method we can offer in your country")
      expect(note.content).to_not include("Add a bank account")
    end

    it "explains the currency restriction for a currency rejection" do
      terminal_failure_for(seller, reason: "PAYPAL 14159")

      described_class.process(dry_run: false)

      expect(seller.comments.with_type_payout_note.last.content)
        .to include("your PayPal account cannot receive US dollars")
    end

    # The seller can clear a currency rejection on the account they already use, and we keep paying
    # them meanwhile, so the note must offer that fix and must not claim the retries stopped.
    # Reviewer finding on #6526.
    it "offers the in-place currency fix for a currency rejection" do
      allow_bank_payouts_for(seller)
      terminal_failure_for(seller, reason: "PAYPAL 14159")

      described_class.process(dry_run: false)

      content = seller.comments.with_type_payout_note.last.content
      expect(content).to include("Sign in to PayPal and add US dollars to the currencies your account can receive")
      expect(content).to_not include("stopped retrying")
    end

    it "asks a seller whose account is also on hold to reply, rather than promising a payout date" do
      terminal_failure_for(seller)
      seller.update!(payouts_paused_internally: true)

      described_class.process(dry_run: false)

      note = seller.comments.with_type_payout_note.last
      expect(note.content).to include("Payouts on your account are also on hold")
      expect(note.content).to_not include("next payout date")
    end

    # A payout note is not something a seller can reply to — only the email is.
    it "sends a seller on hold to support rather than telling them to reply to the note" do
      terminal_failure_for(seller)
      seller.update!(payouts_paused_internally: true)

      described_class.process(dry_run: false)

      note = seller.comments.with_type_payout_note.last
      expect(note.content).to include("contact support")
      expect(note.content).to_not include("reply to this message")
    end

    # The payout gate checks the broader payouts_paused?, so a self-paused seller is skipped as
    # well — the plain "next payout date" promise on its own would not come true for them.
    it "names their own pause for a seller who paused their payouts themselves" do
      terminal_failure_for(seller)
      seller.update!(payouts_paused_by_user: true)

      described_class.process(dry_run: false)

      note = seller.comments.with_type_payout_note.last
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

      expect(seller.comments.with_type_payout_note.last.content)
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

      note = seller.comments.with_type_payout_note.last
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
      end.to change { seller.comments.with_type_payout_note.count }.from(0).to(1)
    end

    it "does not write a second note when run again" do
      terminal_failure_for(seller)
      described_class.process(dry_run: false)

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    # A note about the address they walked away from is not an explanation of the block they are
    # under now: it names a different date, and possibly the other of the two PayPal restrictions.
    it "explains the current block even when an older address was already explained" do
      terminal_failure_for(seller, reason: "PAYPAL 3148", created_at: 10.weeks.ago)
      described_class.process(dry_run: false)
      expect(seller.comments.with_type_payout_note.count).to eq(1)

      seller.update!(payment_address: "current@example.com")
      current = terminal_failure_for(seller, reason: "PAYPAL 14159", created_at: 1.week.ago)

      expect do
        described_class.process(dry_run: false)
      end.to change { seller.comments.with_type_payout_note.count }.from(1).to(2)

      expect(seller.comments.with_type_payout_note.last.content)
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

      expect(seller.comments.with_type_payout_note.last.content)
        .to eq(blocking.terminal_paypal_failure_seller_note)
        .and include("payments cannot be received in the country on that account's address")
    end

    it "skips a seller who has since switched to a bank account" do
      terminal_failure_for(seller)
      create(:ach_account, user: seller)
      seller.update!(payment_address: "")

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller.comments.with_type_payout_note.count }
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
      end.to_not change { seller.comments.with_type_payout_note.count }
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
      end.to_not change { seller.comments.with_type_payout_note.count }
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
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    # A closed account is paused internally and will not be paid whatever the seller does, so the
    # "reply and we'll review the hold" copy would send them to support for nothing.
    it "skips a closed account" do
      terminal_failure_for(seller)
      seller.update!(deleted_at: Time.current)

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "skips a seller who has since changed their PayPal address" do
      terminal_failure_for(seller)
      seller.update!(payment_address: "working@example.com")

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "skips a seller who has been paid out since the rejection" do
      terminal_failure_for(seller, created_at: 4.weeks.ago)
      create(:payment_completed, user: seller, payment_address: seller.payment_address, created_at: 1.week.ago)

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "ignores retryable rejections" do
      terminal_failure_for(seller, reason: "PAYPAL 3015")

      expect do
        described_class.process(dry_run: false)
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "writes nothing on a dry run" do
      terminal_failure_for(seller)

      expect do
        expect(described_class.process(dry_run: true)).to eq(noted: 1, skipped: 0)
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    # Writing seller-visible notes to the whole population must be asked for, not the accident of
    # typing the shortest thing that runs. Reviewer finding on #6526.
    it "reports without writing when no dry_run is given" do
      terminal_failure_for(seller)

      expect do
        expect(described_class.process).to eq(noted: 1, skipped: 0)
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "reports without writing when the instance method is called with no dry_run" do
      terminal_failure_for(seller)

      expect do
        described_class.new.process
      end.to_not change { seller.comments.with_type_payout_note.count }
    end
  end
end
