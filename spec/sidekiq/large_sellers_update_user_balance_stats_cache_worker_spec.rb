# frozen_string_literal: true

require "spec_helper"

describe LargeSellersUpdateUserBalanceStatsCacheWorker do
  describe "#perform" do
    it "queues a job for each cacheable user" do
      ids = create_list(:user, 2).map(&:id)
      expect(UserBalanceStatsService).to receive(:cacheable_users).and_return(User.where(id: ids))
      described_class.new.perform
      expect(UpdateUserBalanceStatsCacheWorker).to have_enqueued_sidekiq_job(ids[0])
      expect(UpdateUserBalanceStatsCacheWorker).to have_enqueued_sidekiq_job(ids[1])
    end
  end
end
