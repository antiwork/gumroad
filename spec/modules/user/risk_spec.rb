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
        .and not_change { SuspendAccountsWithStripeFingerprintWorker.jobs.size }
       
        expect do
          SuspendAccountsWithPaymentAddressWorker.perform_one
        end.to change(SuspendAccountsWithPaymentAddressWorker.jobs, :size).from(1).to(0)
        .and not_change { SuspendAccountsWithStripeFingerprintWorker.jobs.size }      
      end
    end

    context "when user has Stripe as payout processor" do
      it "calls SuspendAccountsWithStripeFingerprintWorker only once for all related accounts" do
        stripe_fingerprint = SecureRandom.hex(16)
        user = create(:user, payment_address: nil)
        user2 = create(:user, payment_address: nil)
        [user, user2].each do |user|
          create(:user_compliance_info, user:)
          create(:ach_account, user:, stripe_fingerprint:)
        end

        expect do
          user.suspend_sellers_other_accounts(transition)
        end.to change(SuspendAccountsWithStripeFingerprintWorker.jobs, :size).from(0).to(1)
        .and change { SuspendAccountsWithStripeFingerprintWorker.jobs.last&.dig('args') }.to([user.id])
        .and not_change { SuspendAccountsWithPaymentAddressWorker.jobs.size }

        expect do
          SuspendAccountsWithStripeFingerprintWorker.perform_one
        end.to change(SuspendAccountsWithStripeFingerprintWorker.jobs, :size).from(1).to(0)
        .and not_change { SuspendAccountsWithPaymentAddressWorker.jobs.size }
      end
    end
  end

  describe "#enable_sellers_other_accounts" do
    let(:transition) { double("transition", args: []) }

    context "when user has Stripe as payout processor" do
      it "calls MarkAccountsCompliantWithStripeFingerprintWorker only once for all related accounts" do
        stripe_fingerprint = SecureRandom.hex(16)
        user = create(:user, payment_address: nil)
        user2 = create(:user, payment_address: nil)
        [user, user2].each do |user|
          create(:user_compliance_info, user:)
          create(:ach_account, user:, stripe_fingerprint:)
        end

        expect do
          user.enable_sellers_other_accounts(transition)
        end.to change(MarkAccountsCompliantWithStripeFingerprintWorker.jobs, :size).from(0).to(1)
        .and change { MarkAccountsCompliantWithStripeFingerprintWorker.jobs.last&.dig('args') }.to([user.id])

        expect do
          MarkAccountsCompliantWithStripeFingerprintWorker.perform_one
        end.to change(MarkAccountsCompliantWithStripeFingerprintWorker.jobs, :size).from(1).to(0)
      end
    end
  end
end
