# frozen_string_literal: true

require "spec_helper"

describe User::Risk do
  describe "#disable_refunds!" do
    before do
      @creator = create(:user)
    end

    it "disables refunds for the creator" do
      @creator.disable_refunds!
      expect(@creator.reload.refunds_disabled?).to eq(true)
    end
  end

  describe "#log_suspension_time_to_mongo", :sidekiq_inline do
    let(:user) { create(:user) }
    let(:collection) { MONGO_DATABASE[MongoCollections::USER_SUSPENSION_TIME] }

    it "writes suspension data to mongo collection" do
      freeze_time do
        user.log_suspension_time_to_mongo

        record = collection.find("user_id" => user.id).first
        expect(record).to be_present
        expect(record["user_id"]).to eq(user.id)
        expect(record["suspended_at"]).to eq(Time.current.to_s)
      end
    end
  end

  describe ".refund_queue", :sidekiq_inline do
    it "returns users suspended for fraud with positive unpaid balances" do
      user = create(:user)
      create(:balance, user: user, amount_cents: 5000, state: "unpaid")
      user.flag_for_fraud!(author_name: "admin")
      user.suspend_for_fraud!(author_name: "admin")

      result = User.refund_queue

      expect(result.to_a).to eq([user])
    end
  end

  describe "#suspend_sellers_other_accounts" do
    let(:transition) { double("transition", args: []) }

    context "when user has PayPal as payout processor" do
      it "calls SuspendAccountsWithPaymentAddressWorker only once for all related accounts" do
        user = create(:user, payment_address: "test@example.com")
        create(:user, payment_address: "test@example.com")

        expect do
          user.suspend_sellers_other_accounts(transition)
        end.to change(SuspendAccountsWithPaymentAddressWorker.jobs, :size).from(0).to(1)
        .and change { SuspendAccountsWithPaymentAddressWorker.jobs.last&.dig("args") }.to([user.id])

        expect do
          SuspendAccountsWithPaymentAddressWorker.perform_one
        end.to change(SuspendAccountsWithPaymentAddressWorker.jobs, :size).from(1).to(0)
      end
    end

    context "when user has ACH bank account with stripe fingerprint" do
      it "calls SuspendAccountsWithStripeFingerprintWorker" do
        user = create(:user)
        create(:ach_account, user: user, stripe_fingerprint: "fp_123")

        expect do
          user.suspend_sellers_other_accounts(transition)
        end.to change(SuspendAccountsWithStripeFingerprintWorker.jobs, :size).from(0).to(1)
        .and change { SuspendAccountsWithStripeFingerprintWorker.jobs.last&.dig("args") }.to([user.id])
      end
    end
  end

  describe "#enable_sellers_other_accounts" do
    let(:transition) { double("transition", args: [{}]) }

    context "when related users share the same stripe fingerprint" do
      it "marks related users as compliant" do
        user = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: user, stripe_fingerprint: "fp_shared")

        related_user = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: related_user, stripe_fingerprint: "fp_shared")

        user.enable_sellers_other_accounts(transition)

        expect(related_user.reload.compliant?).to be(true)
      end

      it "does not mark the original user as compliant" do
        user = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: user, stripe_fingerprint: "fp_shared")

        user.enable_sellers_other_accounts(transition)

        expect(user.reload.suspended_for_fraud?).to be(true)
      end

      it "handles multiple related users" do
        user = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: user, stripe_fingerprint: "fp_shared")

        related_user_1 = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: related_user_1, stripe_fingerprint: "fp_shared")

        related_user_2 = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: related_user_2, stripe_fingerprint: "fp_shared")

        user.enable_sellers_other_accounts(transition)

        expect(related_user_1.reload.compliant?).to be(true)
        expect(related_user_2.reload.compliant?).to be(true)
      end

      it "checks all bank accounts including deleted ones" do
        user = create(:user, user_risk_state: "suspended_for_fraud")
        deleted_bank = create(:ach_account, user: user, stripe_fingerprint: "fp_deleted")
        deleted_bank.mark_deleted!

        related_user = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: related_user, stripe_fingerprint: "fp_deleted")

        user.enable_sellers_other_accounts(transition)

        expect(related_user.reload.compliant?).to be(true)
      end
    end
  end
end
