# frozen_string_literal: true

require "spec_helper"

describe UpdateUserBalanceStatsCacheWorker do
  describe "#perform" do
    it "writes cache" do
      user = create(:user)
      expect(UserBalanceStatsService.new(user:).send(:read_cache)).to eq(nil)
      described_class.new.perform(user.id)
      expect(UserBalanceStatsService.new(user:).send(:read_cache)).not_to eq(nil)
    end
  end
end
