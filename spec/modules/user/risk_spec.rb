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
end
