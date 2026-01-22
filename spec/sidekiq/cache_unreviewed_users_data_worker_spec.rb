# frozen_string_literal: true

require "spec_helper"

describe CacheUnreviewedUsersDataWorker do
  describe "#perform" do
    it "caches unreviewed users data via the service" do
      user = create(:user, user_risk_state: "not_reviewed", created_at: 1.year.ago)
      create(:balance, user:, amount_cents: 5000)

      described_class.new.perform

      cached_data = Admin::UnreviewedUsersService.cached_users_data
      expect(cached_data[:users].size).to eq(1)
      expect(cached_data[:users].first[:external_id]).to eq(user.external_id)
    end
  end
end
