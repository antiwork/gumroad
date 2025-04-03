# frozen_string_literal: true

require "spec_helper"

describe SubscriptionPlanChange do
  describe "validations" do
    it "validates presence of tier for a tiered membership" do
      subscription = create(:subscription, link: create(:membership_product))
      record = build(:subscription_plan_change, subscription:, tier: nil)
      expect(record).not_to be_valid
    end

    it "does not validate presence of tier for a non-tiered membership subscription" do
      record = build(:subscription_plan_change, tier: nil)
      expect(record).to be_valid
    end

    it "validates presence of subscription" do
      record = build(:subscription_plan_change, subscription: nil)
      expect(record).not_to be_valid
    end

    it "validates presence of recurrence" do
      record = build(:subscription_plan_change, recurrence: nil)
      expect(record).not_to be_valid
    end

    it "validates inclusion of recurrence in allowed recurrences" do
      BasePrice::Recurrence::ALLOWED_RECURRENCES.each do |recurrence|
        record = build(:subscription_plan_change, recurrence:)
        expect(record).to be_valid
      end
      ["biweekly", "foo"].each do |recurrence|
        record = build(:subscription_plan_change, recurrence:)
        expect(record).not_to be_valid
      end
    end

    it "validates the presence of perceived_price_cents" do
      record = build(:subscription_plan_change, perceived_price_cents: nil)
      expect(record).not_to be_valid
    end
  end

  describe "scopes" do
    describe ".applicable_for_product_price_change_as_of" do
      it "returns the applicable product price changes as of a given date" do
        create(:subscription_plan_change, for_product_price_change: true, effective_on: 1.week.from_now)
        create(:subscription_plan_change, for_product_price_change: true, effective_on: 1.day.ago, deleted_at: 12.hours.ago)
        create(:subscription_plan_change, for_product_price_change: true, effective_on: 1.day.ago, applied: true)
        create(:subscription_plan_change)

        applicable = [
          create(:subscription_plan_change, for_product_price_change: true, effective_on: 1.day.ago),
        ]

        expect(described_class.applicable_for_product_price_change_as_of(Date.today)).to match_array applicable
      end
    end

    describe ".currently_applicable" do
      it "returns the currently applicable plan changes" do
        create(:subscription_plan_change, deleted_at: 1.week.ago)
        create(:subscription_plan_change, applied: true)

        create(:subscription_plan_change, for_product_price_change: true, effective_on: 1.week.from_now)
        create(:subscription_plan_change, for_product_price_change: true, effective_on: 2.days.ago, notified_subscriber_at: nil)
        create(:subscription_plan_change, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago, deleted_at: 12.hours.ago)
        create(:subscription_plan_change, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago, applied: true)

        applicable = [
          create(:subscription_plan_change, for_product_price_change: true, effective_on: 1.day.ago, notified_subscriber_at: 1.day.ago),
          create(:subscription_plan_change),
        ]

        expect(described_class.currently_applicable).to match_array applicable
      end
    end
  end

  describe "#formatted_display_price" do
    it "returns the formatted price" do
      plan_change = create(:subscription_plan_change, recurrence: "every_two_years", perceived_price_cents: 3099)
      expect(plan_change.formatted_display_price).to eq "$30.99 every 2 years"

      plan_change = create(:subscription_plan_change, recurrence: "yearly", perceived_price_cents: 1599)
      expect(plan_change.formatted_display_price).to eq "$15.99 a year"

      plan_change.update!(perceived_price_cents: 100, recurrence: "quarterly")
      expect(plan_change.formatted_display_price).to eq "$1 every 3 months"

      plan_change.update!(perceived_price_cents: 350, recurrence: "monthly")
      plan_change.subscription.link.update!(price_currency_type: "eur")
      expect(plan_change.formatted_display_price).to eq "€3.50 a month"
    end

    it "returns the formatted price for a subscription with a set end date" do
      subscription = create(:subscription, charge_occurrence_count: 5)
      plan_change = create(:subscription_plan_change, subscription:, recurrence: "monthly", perceived_price_cents: 1599)
      expect(plan_change.formatted_display_price).to eq "$15.99 a month x 5"
    end
  end
end
