# frozen_string_literal: true

require "spec_helper"

describe Onetime::ExplainTerminalPaypalPayoutFailures do
  describe ".process" do
    let(:seller) { create(:user, payment_address: "stuck@example.com") }

    def terminal_failure_for(user, reason: "PAYPAL 3148", created_at: 2.weeks.ago)
      create(:payment_failed, user:, payment_address: user.payment_address,
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
        described_class.process
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

      described_class.process

      note = seller.comments.with_type_payout_note.last
      expect(note.content).to include("PayPal is the only payout method we can offer in your country")
      expect(note.content).to_not include("Add a bank account")
    end

    it "explains the currency restriction for a currency rejection" do
      terminal_failure_for(seller, reason: "PAYPAL 14159")

      described_class.process

      expect(seller.comments.with_type_payout_note.last.content)
        .to include("your PayPal account cannot receive US dollars")
    end

    it "asks a seller whose account is also on hold to reply, rather than promising a payout date" do
      terminal_failure_for(seller)
      seller.update!(payouts_paused_internally: true)

      described_class.process

      note = seller.comments.with_type_payout_note.last
      expect(note.content).to include("Payouts on your account are also on hold")
      expect(note.content).to_not include("next payout date")
    end

    it "describes the most recent rejection when the seller has several" do
      terminal_failure_for(seller, created_at: 10.weeks.ago)
      latest = terminal_failure_for(seller, reason: "PAYPAL 14159", created_at: 1.week.ago)

      described_class.process

      expect(seller.comments.with_type_payout_note.last.content)
        .to include("your PayPal account cannot receive US dollars")
        .and include(latest.created_at.to_fs(:formatted_date_full_month))
    end

    it "does not write a second note when run again" do
      terminal_failure_for(seller)
      described_class.process

      expect do
        described_class.process
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "skips a seller who has since switched to a bank account" do
      terminal_failure_for(seller)
      create(:ach_account, user: seller)
      seller.update!(payment_address: "")

      expect do
        described_class.process
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "skips a seller who has since changed their PayPal address" do
      terminal_failure_for(seller)
      seller.update!(payment_address: "working@example.com")

      expect do
        described_class.process
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "skips a seller who has been paid out since the rejection" do
      terminal_failure_for(seller, created_at: 4.weeks.ago)
      create(:payment_completed, user: seller, payment_address: seller.payment_address, created_at: 1.week.ago)

      expect do
        described_class.process
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "ignores retryable rejections" do
      terminal_failure_for(seller, reason: "PAYPAL 3015")

      expect do
        described_class.process
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "ignores rejections older than the lookback window" do
      terminal_failure_for(seller, created_at: (described_class::LOOKBACK + 10.days).ago)

      expect do
        described_class.process
      end.to_not change { seller.comments.with_type_payout_note.count }
    end

    it "writes nothing on a dry run" do
      terminal_failure_for(seller)

      expect do
        expect(described_class.process(dry_run: true)).to eq(noted: 1, skipped: 0)
      end.to_not change { seller.comments.with_type_payout_note.count }
    end
  end
end
