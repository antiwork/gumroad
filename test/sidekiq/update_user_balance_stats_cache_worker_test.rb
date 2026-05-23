# frozen_string_literal: true

require "test_helper"

class UpdateUserBalanceStatsCacheWorkerTest < ActiveSupport::TestCase
  self.described_class = UpdateUserBalanceStatsCacheWorker



  context_ UpdateUserBalanceStatsCacheWorker do
  context_ "#perform" do
  test "writes cache" do
        user = create(:user)
        expect(UserBalanceStatsService.new(user:).send(:read_cache)).to eq(nil)
        described_class.new.perform(user.id)
        expect(UserBalanceStatsService.new(user:).send(:read_cache)).not_to eq(nil)
      end
    end
  end
end
