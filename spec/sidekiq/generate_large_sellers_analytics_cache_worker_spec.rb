# frozen_string_literal: true

require "spec_helper"

describe GenerateLargeSellersAnalyticsCacheWorker do
  describe "#perform" do
    before do
      @user_1 = create(:user)
      create(:large_seller, user: @user_1)
      @user_2 = create(:user)
      create(:large_seller, user: @user_2)
      create(:user, current_sign_in_at: 1.day.ago) # not a large seller
    end

    it "calls CreatorAnalytics::CachingProxy#generate_cache on large sellers" do
      [@user_1, @user_2].each do |user|
        service_object = double("CreatorAnalytics::CachingProxy object")
        expect(CreatorAnalytics::CachingProxy).to receive(:new).with(user).and_return(service_object)
        expect(service_object).to receive(:generate_cache)
      end

      described_class.new.perform
    end

    it "rescues and report errors" do
      # user 1
      expect(CreatorAnalytics::CachingProxy).to receive(:new).with(@user_1).and_raise("Something went wrong")
      expect(Bugsnag).to receive(:notify) do |exception|
        expect(exception.message).to eq("Something went wrong")
      end
      # user 2
      service_object = double("CreatorAnalytics::CachingProxy object")
      expect(CreatorAnalytics::CachingProxy).to receive(:new).with(@user_2).and_return(service_object)
      expect(service_object).to receive(:generate_cache)

      described_class.new.perform
    end
  end
end
