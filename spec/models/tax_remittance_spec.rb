# frozen_string_literal: true

require "spec_helper"

describe TaxRemittance do
  describe "validations" do
    it "is valid with the standard attributes" do
      expect(build(:tax_remittance)).to be_valid
    end

    it "requires a quarterly period format" do
      expect(build(:tax_remittance, period: "2026-Q5")).not_to be_valid
      expect(build(:tax_remittance, period: "April 2026")).not_to be_valid
      expect(build(:tax_remittance, period: "2026-Q4")).to be_valid
    end

    it "rejects unknown rails and statuses" do
      expect(build(:tax_remittance, rail: "paypal")).not_to be_valid
      expect(build(:tax_remittance, status: "maybe")).not_to be_valid
    end

    it "enforces one remittance per authority per period per attempt" do
      create(:tax_remittance)
      dup = build(:tax_remittance, status: "failed")
      expect(dup).not_to be_valid
      expect(dup.errors[:authority]).to be_present
    end

    it "allows the same authority in a different period" do
      create(:tax_remittance)
      expect(build(:tax_remittance, period: "2026-Q2")).to be_valid
    end

    it "enforces one remittance per rail-side transfer" do
      create(:tax_remittance, transfer_id: "WISE-123")

      dup = build(:tax_remittance, authority: "IRAS Singapore", jurisdiction: "SG", currency: "SGD", transfer_id: "WISE-123")
      expect(dup).not_to be_valid
      expect(dup.errors[:transfer_id]).to be_present

      # Same transfer ID on a different rail is a different payment.
      expect(build(:tax_remittance, authority: "Australian Taxation Office", jurisdiction: "AU", currency: "AUD",
                                    rail: "mercury", transfer_id: "WISE-123")).to be_valid
    end

    it "allows many rows without a transfer ID yet" do
      create(:tax_remittance, transfer_id: nil)
      expect(build(:tax_remittance, authority: "IRAS Singapore", jurisdiction: "SG", currency: "SGD", transfer_id: nil)).to be_valid
    end

    it "requires paid_at once the payment has been sent" do
      expect(build(:tax_remittance, status: "sent", paid_at: nil)).not_to be_valid
      expect(build(:tax_remittance, status: "completed", paid_at: nil)).not_to be_valid
      expect(build(:tax_remittance, :completed)).to be_valid
      expect(build(:tax_remittance, status: "draft", paid_at: nil)).to be_valid
    end

    it "requires a positive USD amount" do
      expect(build(:tax_remittance, usd_amount_cents: 0)).not_to be_valid
      expect(build(:tax_remittance, usd_amount_cents: nil)).not_to be_valid
    end

    it "allows target_amount_cents to be nil for QBO-backfilled rows" do
      expect(build(:tax_remittance, target_amount_cents: nil)).to be_valid
      expect(build(:tax_remittance, target_amount_cents: 0)).not_to be_valid
      expect(build(:tax_remittance, target_amount_cents: 20_000_000)).to be_valid
    end

    it "allows only one live attempt per filing" do
      create(:tax_remittance)

      concurrent = build(:tax_remittance, attempt: 2)
      expect(concurrent).not_to be_valid
      expect(concurrent.errors[:base].first).to include("another live attempt")

      # A failed/cancelled attempt doesn't block a new live one.
      expect(build(:tax_remittance, attempt: 2, status: "failed")).to be_valid
    end
  end

  describe ".period_for" do
    it "maps dates to filing quarters" do
      expect(described_class.period_for(Date.new(2026, 1, 1))).to eq("2026-Q1")
      expect(described_class.period_for(Date.new(2026, 3, 31))).to eq("2026-Q1")
      expect(described_class.period_for(Date.new(2026, 4, 1))).to eq("2026-Q2")
      expect(described_class.period_for(Date.new(2026, 12, 31))).to eq("2026-Q4")
    end
  end

  describe "#terminal?" do
    it "is true only for completed, failed, and cancelled" do
      expect(build(:tax_remittance, :completed)).to be_terminal
      expect(build(:tax_remittance, :failed)).to be_terminal
      expect(build(:tax_remittance, status: "cancelled")).to be_terminal
      expect(build(:tax_remittance, status: "draft")).not_to be_terminal
      expect(build(:tax_remittance, status: "pending_approval")).not_to be_terminal
    end
  end

  describe "terminal row immutability" do
    it "refuses to move a completed remittance back to a non-terminal status" do
      remittance = create(:tax_remittance, :completed)

      remittance.status = "draft"
      expect(remittance).not_to be_valid
      expect(remittance.errors[:status].first).to include("cannot change on a completed remittance")
      expect(remittance.reload.status).to eq("completed")
    end

    it "refuses terminal-to-terminal changes too" do
      remittance = create(:tax_remittance, :failed)

      remittance.status = "cancelled"
      expect(remittance).not_to be_valid
    end

    it "freezes the financial identity of a terminal remittance" do
      remittance = create(:tax_remittance, :completed)

      {
        usd_amount_cents: 1,
        authority: "IRAS Singapore",
        period: "2026-Q3",
        currency: "SGD",
        rail: "mercury",
        paid_at: Time.utc(2027, 1, 1),
      }.each do |field, value|
        remittance.reload.assign_attributes(field => value)
        expect(remittance).not_to be_valid, "expected #{field} to be frozen on a completed remittance"
        expect(remittance.errors[field]).to be_present
      end
    end

    it "allows nil→value enrichment of reconciliation fields, but freezes them once set" do
      remittance = create(:tax_remittance, :completed, target_amount_cents: nil, transfer_id: nil)

      # The Wise statement sync learns these after the fact.
      remittance.update!(target_amount_cents: 20_000_000, transfer_id: "WISE-42")

      remittance.target_amount_cents = 1
      expect(remittance).not_to be_valid
      expect(remittance.errors[:target_amount_cents].first).to include("cannot change once set")

      remittance.reload.transfer_id = "WISE-99"
      expect(remittance).not_to be_valid
    end

    it "still allows annotation updates on a terminal remittance" do
      remittance = create(:tax_remittance, :completed)

      remittance.qbo_journal_entry_ref = "JE-1234"
      remittance.notes = "reconciled"
      expect(remittance).to be_valid
      expect(remittance.save).to be(true)
    end

    it "allows normal forward transitions on non-terminal rows" do
      remittance = create(:tax_remittance)

      remittance.update!(status: "pending_approval")
      remittance.update!(status: "completed", paid_at: Time.current)
      expect(remittance.reload.status).to eq("completed")
    end
  end

  describe "sent row immutability" do
    it "refuses to move a sent remittance back to an actionable status" do
      remittance = create(:tax_remittance, :sent)

      %w[draft pending_approval funded].each do |regression|
        remittance.reload.status = regression
        expect(remittance).not_to be_valid, "expected sent → #{regression} to be rejected"
        expect(remittance.errors[:status].first).to include("can only move from sent")
      end
      expect(remittance.reload.status).to eq("sent")
    end

    it "allows a sent remittance to advance to its supported outcomes" do
      %w[completed failed cancelled].each do |outcome|
        remittance = create(:tax_remittance, :sent, period: "2026-Q#{%w[completed failed cancelled].index(outcome) + 1}")

        remittance.status = outcome
        expect(remittance).to be_valid, "expected sent → #{outcome} to be allowed"
        expect(remittance.save).to be(true)
      end
    end

    it "freezes the payment identity of a sent remittance" do
      remittance = create(:tax_remittance, :sent)

      {
        usd_amount_cents: 1,
        authority: "IRAS Singapore",
        period: "2026-Q3",
        currency: "SGD",
        rail: "mercury",
        attempt: 7,
        paid_at: Time.utc(2027, 1, 1),
      }.each do |field, value|
        remittance.reload.assign_attributes(field => value)
        expect(remittance).not_to be_valid, "expected #{field} to be frozen on a sent remittance"
        expect(remittance.errors[field]).to be_present
      end
    end

    it "still allows reconciliation enrichment and annotations on a sent remittance" do
      remittance = create(:tax_remittance, :sent, target_amount_cents: nil, transfer_id: nil)

      remittance.update!(target_amount_cents: 20_000_000, transfer_id: "WISE-42", notes: "in flight", qbo_journal_entry_ref: "JE-9")

      # But once set, the reconciliation fields freeze — same as terminal rows.
      remittance.reload.target_amount_cents = 1
      expect(remittance).not_to be_valid
      expect(remittance.errors[:target_amount_cents].first).to include("cannot change once set")
    end
  end

  describe "#build_retry" do
    it "builds the next attempt for a failed remittance, preserving the failed row" do
      failed = create(:tax_remittance, :failed)

      retry_attempt = failed.build_retry
      expect(retry_attempt).to be_valid
      retry_attempt.save!

      expect(retry_attempt.attempt).to eq(2)
      expect(retry_attempt.status).to eq("draft")
      expect(retry_attempt.authority).to eq(failed.authority)
      expect(retry_attempt.usd_amount_cents).to eq(failed.usd_amount_cents)
      expect(failed.reload.status).to eq("failed")
      expect(described_class.where(authority: failed.authority, period: failed.period).count).to eq(2)
    end

    it "derives the next attempt from the filing's max, so retrying an older failed attempt skips past newer ones" do
      first = create(:tax_remittance, :failed)
      second = first.build_retry
      second.status = "failed"
      second.save!

      # Retrying from the OLDER failed attempt must produce attempt 3, not
      # collide with the existing attempt 2 on the unique index.
      third = first.build_retry
      expect(third.attempt).to eq(3)
      expect(third).to be_valid
      third.save!

      expect(described_class.where(authority: first.authority, period: first.period).pluck(:attempt)).to contain_exactly(1, 2, 3)
    end

    it "refuses to retry a completed or live remittance" do
      expect { create(:tax_remittance, :completed).build_retry }.to raise_error(ArgumentError, /failed or cancelled/)
      expect { create(:tax_remittance, period: "2026-Q2").build_retry }.to raise_error(ArgumentError, /failed or cancelled/)
    end
  end

  describe "#submit_for_approval!" do
    it "moves a draft to pending_approval when both amounts are still the reviewed ones" do
      draft = create(:tax_remittance, usd_amount_cents: 10_00, target_amount_cents: 8_00)

      draft.submit_for_approval!(reviewed_amount_cents: 10_00, reviewed_target_amount_cents: 8_00)

      expect(draft.reload.status).to eq("pending_approval")
    end

    # An approver signing off on a USD estimate alone would be approving half
    # a payment: the amount that actually leaves the account is the
    # target-currency one, and leaving it for whoever funds the row to pick
    # means the payment sent was never reviewed.
    it "refuses to enter approval with no target amount recorded" do
      draft = create(:tax_remittance, usd_amount_cents: 10_00, target_amount_cents: nil)

      expect { draft.submit_for_approval!(reviewed_amount_cents: 10_00, reviewed_target_amount_cents: nil) }
        .to raise_error(described_class::TargetAmountMissing)

      expect(draft.reload.status).to eq("draft")
    end

    it "refuses to submit a target amount that changed since the reviewer saw it" do
      draft = create(:tax_remittance, usd_amount_cents: 10_00, target_amount_cents: 8_00)
      reviewed_target_amount_cents = draft.target_amount_cents

      described_class.where(id: draft.id).update_all(target_amount_cents: 9_00)

      expect { draft.submit_for_approval!(reviewed_amount_cents: 10_00, reviewed_target_amount_cents:) }
        .to raise_error(described_class::AmountChangedSinceReview, /target amount is now/)

      expect(draft.reload.status).to eq("draft")
    end

    # The race this guards: the staging service refreshes an untouched draft
    # while a reviewer has it open, then the reviewer submits. Without the
    # check they would push an amount into the approval flow that they never
    # saw.
    it "refuses to submit an amount that changed since the reviewer saw it" do
      draft = create(:tax_remittance, usd_amount_cents: 10_00, target_amount_cents: 8_00)
      reviewed_amount_cents = draft.usd_amount_cents

      # The staging refresh commits in between.
      described_class.where(id: draft.id).update_all(usd_amount_cents: 15_00)

      expect { draft.submit_for_approval!(reviewed_amount_cents:, reviewed_target_amount_cents: 8_00) }
        .to raise_error(described_class::AmountChangedSinceReview, /15\d{2} cents, not the 10\d{2}/)

      # Still a draft, so the reviewer can re-read and submit the real number.
      expect(draft.reload.status).to eq("draft")
      expect(draft.usd_amount_cents).to eq(15_00)

      # And submitting the refreshed amount works.
      draft.submit_for_approval!(reviewed_amount_cents: 15_00, reviewed_target_amount_cents: 8_00)
      expect(draft.reload.status).to eq("pending_approval")
    end

    it "refuses to submit a row that is no longer a draft" do
      remittance = create(:tax_remittance, usd_amount_cents: 10_00, target_amount_cents: 8_00)
      remittance.update!(status: "pending_approval")

      expect { remittance.submit_for_approval!(reviewed_amount_cents: 10_00, reviewed_target_amount_cents: 8_00) }
        .to raise_error(ArgumentError, /can only submit a draft/)
    end
  end

  describe "amounts bound by an approval" do
    # The gap this closes: only sent/terminal rows used to be protected, so the
    # target-currency amount — the figure that actually leaves the account —
    # could be rewritten after a human approved the row, and the payment sent
    # would not be the payment approved.
    it "refuses to change either approved amount on a pending_approval or funded row" do
      remittance = create(:tax_remittance, usd_amount_cents: 10_00, target_amount_cents: 8_00)
      remittance.submit_for_approval!(reviewed_amount_cents: 10_00, reviewed_target_amount_cents: 8_00)

      expect(remittance.update(target_amount_cents: 9_00)).to be(false)
      expect(remittance.errors[:target_amount_cents].first).to include("without revoking the approval")

      expect(remittance.reload.update(usd_amount_cents: 12_00)).to be(false)
      expect(remittance.errors[:usd_amount_cents].first).to include("without revoking the approval")

      remittance.reload.update!(status: "funded")
      expect(remittance.update(target_amount_cents: 9_00)).to be(false)

      # Annotations are still writable — they describe the payment, not what
      # was approved.
      expect(remittance.reload.update(notes: "chased with the tax agent")).to be(true)
    end

    # Correcting an approved amount is possible; it just costs the approval, so
    # the corrected numbers get reviewed a second time before anything is
    # funded.
    it "allows the amounts to change again once the approval is revoked" do
      remittance = create(:tax_remittance, usd_amount_cents: 10_00, target_amount_cents: 8_00)
      remittance.submit_for_approval!(reviewed_amount_cents: 10_00, reviewed_target_amount_cents: 8_00)

      remittance.revoke_approval!
      expect(remittance.reload.status).to eq("draft")

      remittance.record_target_amount!(9_00)
      expect(remittance.reload.target_amount_cents).to eq(9_00)

      remittance.submit_for_approval!(reviewed_amount_cents: 10_00, reviewed_target_amount_cents: 9_00)
      expect(remittance.reload.status).to eq("pending_approval")
    end

    it "refuses to set a target amount on anything but a draft, and refuses to revoke a sent payment" do
      remittance = create(:tax_remittance, usd_amount_cents: 10_00, target_amount_cents: 8_00)
      remittance.submit_for_approval!(reviewed_amount_cents: 10_00, reviewed_target_amount_cents: 8_00)

      expect { remittance.record_target_amount!(9_00) }.to raise_error(ArgumentError, /only set a target amount on a draft/)

      sent = create(:tax_remittance, :sent, authority: "IRAS Singapore", jurisdiction: "SG", currency: "SGD")
      expect { sent.revoke_approval! }.to raise_error(ArgumentError, /can only revoke approval/)
    end
  end

  describe "scopes" do
    it "separates in-progress from terminal remittances" do
      draft = create(:tax_remittance)
      done = create(:tax_remittance, :completed, authority: "IRAS Singapore", jurisdiction: "SG", currency: "SGD")

      expect(described_class.in_progress).to contain_exactly(draft)
      expect(described_class.completed).to contain_exactly(done)
    end
  end
end
