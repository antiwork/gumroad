# frozen_string_literal: true

require "test_helper"

class LargeSellersUpdateUserBalanceStatsCacheWorkerTest < ActiveSupport::TestCase
  self.described_class = LargeSellersUpdateUserBalanceStatsCacheWorker



  context_ LargeSellersUpdateUserBalanceStatsCacheWorker do
  context_ "#perform" do
  test "queues a job for each cacheable user" do
        ids = create_list(:user, 2).map(&:id)
        expect(UserBalanceStatsService).to receive(:cacheable_users).and_return(User.where(id: ids))
        described_class.new.perform
        expect(UpdateUserBalanceStatsCacheWorker).to have_enqueued_sidekiq_job(ids[0])
        expect(UpdateUserBalanceStatsCacheWorker).to have_enqueued_sidekiq_job(ids[1])
      end
    end
  end
end
