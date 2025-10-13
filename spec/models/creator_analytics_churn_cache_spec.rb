# frozen_string_literal: true

require "spec_helper"

RSpec.describe CreatorAnalyticsChurnCache, type: :model do
  describe "validations" do
    let(:user) { create(:user) }

    it "validates presence of date" do
      cache = described_class.new(user: user)
      expect(cache).not_to be_valid
      expect(cache.errors[:date]).to include("can't be blank")
    end

    it "validates uniqueness of date scoped to user" do
      date = Date.current
      create(:creator_analytics_churn_cache, user: user, date: date)

      duplicate = described_class.new(user: user, date: date)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:date]).to include("has already been taken")
    end

    it "validates churned_subscribers is non-negative" do
      cache = described_class.new(
        user: user,
        date: Date.current,
        churned_subscribers: -1
      )
      expect(cache).not_to be_valid
    end

    it "validates churned_mrr_cents is non-negative" do
      cache = described_class.new(
        user: user,
        date: Date.current,
        churned_mrr_cents: -1
      )
      expect(cache).not_to be_valid
    end

    it "validates churn rate is between 0 and 100" do
      cache = described_class.new(
        user: user,
        date: Date.current,
        customer_churn_rate: 150
      )
      expect(cache).not_to be_valid
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }

    describe ".for_date_range" do
      it "returns records within date range" do
        cache1 = create(:creator_analytics_churn_cache, user: user, date: 10.days.ago)
        cache2 = create(:creator_analytics_churn_cache, user: user, date: 5.days.ago)
        cache3 = create(:creator_analytics_churn_cache, user: user, date: 20.days.ago)

        results = described_class.for_date_range(15.days.ago, Date.current)
        expect(results).to include(cache1, cache2)
        expect(results).not_to include(cache3)
      end
    end

    describe ".recent" do
      it "returns records from last 90 days" do
        recent = create(:creator_analytics_churn_cache, user: user, date: 30.days.ago)
        old = create(:creator_analytics_churn_cache, user: user, date: 100.days.ago)

        expect(described_class.recent).to include(recent)
        expect(described_class.recent).not_to include(old)
      end
    end
  end
end
