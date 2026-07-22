# frozen_string_literal: true

require "spec_helper"

describe TaxRemittance do
  def build_remittance(attrs = {})
    described_class.new(
      {
        authority: "HMRC",
        jurisdiction: "GB",
        period: "2026-Q1",
        currency: "GBP",
        usd_amount_cents: 25_333_498,
        rail: "wise",
        status: "draft",
      }.merge(attrs)
    )
  end

  describe "validations" do
    it "is valid with the standard attributes" do
      expect(build_remittance).to be_valid
    end

    it "requires a quarterly period format" do
      expect(build_remittance(period: "2026-Q5")).not_to be_valid
      expect(build_remittance(period: "April 2026")).not_to be_valid
      expect(build_remittance(period: "2026-Q4")).to be_valid
    end

    it "rejects unknown rails and statuses" do
      expect(build_remittance(rail: "paypal")).not_to be_valid
      expect(build_remittance(status: "maybe")).not_to be_valid
    end

    it "enforces one remittance per authority per period" do
      build_remittance.save!
      dup = build_remittance
      expect(dup).not_to be_valid
      expect(dup.errors[:authority]).to be_present
    end

    it "allows the same authority in a different period" do
      build_remittance.save!
      expect(build_remittance(period: "2026-Q2")).to be_valid
    end

    it "enforces one remittance per rail-side transfer" do
      build_remittance(transfer_id: "WISE-123").save!

      dup = build_remittance(authority: "IRAS Singapore", jurisdiction: "SG", currency: "SGD", transfer_id: "WISE-123")
      expect(dup).not_to be_valid
      expect(dup.errors[:transfer_id]).to be_present

      # Same transfer ID on a different rail is a different payment.
      expect(build_remittance(authority: "Australian Taxation Office", jurisdiction: "AU", currency: "AUD",
                              rail: "mercury", transfer_id: "WISE-123")).to be_valid
    end

    it "allows many rows without a transfer ID yet" do
      build_remittance(transfer_id: nil).save!
      expect(build_remittance(authority: "IRAS Singapore", jurisdiction: "SG", currency: "SGD", transfer_id: nil)).to be_valid
    end

    it "requires paid_at once the payment has been sent" do
      expect(build_remittance(status: "sent", paid_at: nil)).not_to be_valid
      expect(build_remittance(status: "completed", paid_at: nil)).not_to be_valid
      expect(build_remittance(status: "completed", paid_at: Time.current)).to be_valid
      expect(build_remittance(status: "draft", paid_at: nil)).to be_valid
    end

    it "requires a positive USD amount" do
      expect(build_remittance(usd_amount_cents: 0)).not_to be_valid
      expect(build_remittance(usd_amount_cents: nil)).not_to be_valid
    end

    it "allows target_amount_cents to be nil for QBO-backfilled rows" do
      expect(build_remittance(target_amount_cents: nil)).to be_valid
      expect(build_remittance(target_amount_cents: 0)).not_to be_valid
      expect(build_remittance(target_amount_cents: 20_000_000)).to be_valid
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
      expect(build_remittance(status: "completed", paid_at: Time.current)).to be_terminal
      expect(build_remittance(status: "failed")).to be_terminal
      expect(build_remittance(status: "cancelled")).to be_terminal
      expect(build_remittance(status: "draft")).not_to be_terminal
      expect(build_remittance(status: "pending_approval")).not_to be_terminal
    end
  end

  describe "terminal status immutability" do
    it "refuses to move a completed remittance back to a non-terminal status" do
      remittance = build_remittance(status: "completed", paid_at: Time.current).tap(&:save!)

      remittance.status = "draft"
      expect(remittance).not_to be_valid
      expect(remittance.errors[:status].first).to include("terminal state completed")
      expect(remittance.reload.status).to eq("completed")
    end

    it "refuses terminal-to-terminal changes too" do
      remittance = build_remittance(status: "failed").tap(&:save!)

      remittance.status = "cancelled"
      expect(remittance).not_to be_valid
    end

    it "allows non-status updates on a terminal remittance" do
      remittance = build_remittance(status: "completed", paid_at: Time.current).tap(&:save!)

      remittance.qbo_journal_entry_ref = "JE-1234"
      expect(remittance).to be_valid
      expect(remittance.save).to be(true)
    end

    it "allows normal forward transitions on non-terminal rows" do
      remittance = build_remittance(status: "draft").tap(&:save!)

      remittance.update!(status: "pending_approval")
      remittance.update!(status: "completed", paid_at: Time.current)
      expect(remittance.reload.status).to eq("completed")
    end
  end

  describe "scopes" do
    it "separates in-progress from terminal remittances" do
      draft = build_remittance.tap(&:save!)
      done = build_remittance(authority: "IRAS Singapore", jurisdiction: "SG", currency: "SGD",
                              status: "completed", paid_at: Time.current).tap(&:save!)

      expect(described_class.in_progress).to contain_exactly(draft)
      expect(described_class.completed).to contain_exactly(done)
    end
  end
end
