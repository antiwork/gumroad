# frozen_string_literal: true

require "spec_helper"

describe Onetime::CleanupWedgedStripeMerchantAccounts do
  before { allow(Stripe::Account).to receive(:delete) }

  def wedged_account(user:, created_at: 8.days.ago)
    create(:merchant_account, user:, charge_processor_alive_at: nil, created_at:)
  end

  describe ".process" do
    it "soft-deletes a wedged Stripe merchant account so the seller can onboard again" do
      user = create(:user)
      merchant_account = wedged_account(user:)

      result = described_class.process(dry_run: false)

      expect(merchant_account.reload.alive?).to be(false)
      expect(result[:cleaned]).to eq(1)
    end

    it "deletes the orphaned half-provisioned Stripe account" do
      user = create(:user)
      merchant_account = wedged_account(user:)

      described_class.process(dry_run: false)

      expect(Stripe::Account).to have_received(:delete).with(merchant_account.charge_processor_merchant_id)
    end

    it "does not modify anything on a dry run" do
      user = create(:user)
      merchant_account = wedged_account(user:)

      result = described_class.process(dry_run: true)

      expect(merchant_account.reload.alive?).to be(true)
      expect(result[:would_clean]).to eq(1)
      expect(result[:cleaned]).to eq(0)
      expect(Stripe::Account).not_to have_received(:delete)
    end

    it "leaves users who have a working Stripe account untouched" do
      user = create(:user)
      create(:merchant_account, user:)
      wedged = wedged_account(user:)

      described_class.process(dry_run: false)

      expect(wedged.reload.alive?).to be(true)
    end

    it "still cleans a wedged row when the only alive-flagged account is soft-deleted" do
      user = create(:user)
      create(:merchant_account, user:).mark_deleted!
      wedged = wedged_account(user:)

      described_class.process(dry_run: false)

      expect(wedged.reload.alive?).to be(false)
    end

    it "skips a candidate that is no longer wedged when re-checked on the primary" do
      user = create(:user)
      merchant_account = wedged_account(user:)
      allow_any_instance_of(MerchantAccount).to receive(:reload).and_wrap_original do |original|
        record = original.call
        record.charge_processor_alive_at = Time.current
        record
      end

      result = described_class.process(dry_run: false)

      expect(result[:skipped_no_longer_wedged]).to eq(1)
      expect(result[:cleaned]).to eq(0)
      expect(Stripe::Account).not_to have_received(:delete)
      expect(MerchantAccount.find(merchant_account.id).alive?).to be(true)
    end

    it "ignores rows recent enough to be a live onboarding" do
      user = create(:user)
      recent = wedged_account(user:, created_at: 1.day.ago)

      result = described_class.process(dry_run: false)

      expect(recent.reload.alive?).to be(true)
      expect(result[:scanned]).to eq(0)
    end

    it "flags wedged owners that still have an unpaid balance" do
      user = create(:user)
      merchant_account = wedged_account(user:)
      create(:balance, user:, merchant_account:, amount_cents: 5_00)

      result = described_class.process(dry_run: false)

      expect(result[:wedged_with_balance]).to eq(1)
    end
  end
end
