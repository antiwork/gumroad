# frozen_string_literal: true

require "spec_helper"

describe LargeSellersUpdateUserBalanceStatsCacheWorker do
  describe "#perform" do
    it "queues a job for each cacheable user" do
      ids = create_list(:user, 2).map(&:id)
      expect(UserBalanceStatsService).to receive(:cacheable_users).and_return(User.where(id: ids))
      described_class.new.perform
      expect(UpdateUserBalanceStatsCacheWorker.jobs.size).to eq(2)
      enqueued_ids = UpdateUserBalanceStatsCacheWorker.jobs.map { |job| job["args"].first }
      expect(enqueued_ids).to match_array(ids)
    end

    it "staggers the enqueued jobs evenly across STAGGER_WINDOW" do
      ids = create_list(:user, 4).map(&:id)
      expect(UserBalanceStatsService).to receive(:cacheable_users).and_return(User.where(id: ids))

      freeze_time do
        described_class.new.perform

        scheduled_times = UpdateUserBalanceStatsCacheWorker.jobs.map { |job| job["at"] }.sort
        expected_step = described_class::STAGGER_WINDOW.to_f / ids.size
        gaps = scheduled_times.each_cons(2).map { |a, b| b - a }

        expect(scheduled_times.first).to be_within(0.01).of(Time.current.to_f)
        expect(gaps).to all(be_within(0.01).of(expected_step))
      end
    end

    it "does nothing when there are no cacheable users" do
      expect(UserBalanceStatsService).to receive(:cacheable_users).and_return(User.none)
      described_class.new.perform
      expect(UpdateUserBalanceStatsCacheWorker.jobs).to be_empty
    end
  end
end
