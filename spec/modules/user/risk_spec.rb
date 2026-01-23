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

    context "when user has a Stripe bank account" do
      it "calls SuspendAccountsWithStripeFingerprintWorker" do
        user = create(:user)
        create(:ach_account, user: user, stripe_fingerprint: "test_fingerprint")

        expect do
          user.suspend_sellers_other_accounts(transition)
        end.to change(SuspendAccountsWithStripeFingerprintWorker.jobs, :size).by(1)

        expect(SuspendAccountsWithStripeFingerprintWorker.jobs.last["args"]).to eq([user.id])
      end
    end
  end

  describe "#enable_sellers_other_accounts" do
    let(:admin) { create(:admin_user) }
    let(:transition) { double("transition", args: [{}]) }

    context "when user has a Stripe bank account with matching fingerprint" do
      it "marks related accounts compliant based on stripe fingerprint" do
        user_1 = create(:user)
        create(:ach_account, user: user_1, stripe_fingerprint: "shared_fingerprint")

        user_2 = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: user_2, stripe_fingerprint: "shared_fingerprint")

        user_1.enable_sellers_other_accounts(transition)

        expect(user_2.reload.compliant?).to be(true)
      end

      it "logs an error and continues when marking a user compliant fails" do
        user_1 = create(:user)
        create(:ach_account, user: user_1, stripe_fingerprint: "shared_fingerprint")

        user_2 = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: user_2, stripe_fingerprint: "shared_fingerprint")

        user_3 = create(:user, user_risk_state: "suspended_for_fraud")
        create(:ach_account, user: user_3, stripe_fingerprint: "shared_fingerprint")

        # Stub mark_compliant! to fail for user_2 only
        call_count = 0
        allow_any_instance_of(User).to receive(:mark_compliant!).and_wrap_original do |method, **args|
          call_count += 1
          if call_count == 1
            raise StandardError.new("test error")
          else
            method.call(**args)
          end
        end

        expect(Rails.logger).to receive(:error).with(/Failed to mark user .* compliant: test error/)

        user_1.enable_sellers_other_accounts(transition)

        # user_3 should still be processed despite user_2 failing
        expect(user_3.reload.compliant?).to be(true)
      end
    end
  end
end
