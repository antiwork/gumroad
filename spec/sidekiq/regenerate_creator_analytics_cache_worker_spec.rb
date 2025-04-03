# frozen_string_literal: true

require "spec_helper"

describe RegenerateCreatorAnalyticsCacheWorker do
  describe "#perform" do
    it "runs CreatorAnalytics::CachingProxy#overwrite_cache" do
      user = create(:user)

      service_object = double("CreatorAnalytics::CachingProxy object")
      expect(CreatorAnalytics::CachingProxy).to receive(:new).with(user).and_return(service_object)
      expect(service_object).to receive(:overwrite_cache).with(Date.new(2020, 7, 5), by: :date)
      expect(service_object).to receive(:overwrite_cache).with(Date.new(2020, 7, 5), by: :state)
      expect(service_object).to receive(:overwrite_cache).with(Date.new(2020, 7, 5), by: :referral)

      described_class.new.perform(user.id, "2020-07-05")
    end
  end
end
