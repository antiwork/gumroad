# frozen_string_literal: true

require "rails_helper"

RSpec.describe CreatorAnalytics::Churn do
  let(:user) { create(:user) }
  let(:product) { create(:subscription_product, user: user) }
  let(:start_date) { 30.days.ago.to_date }
  let(:end_date) { Date.current }
  let(:service) { described_class.new(user: user, start_date: start_date, end_date: end_date) }

  describe "#calculate" do
    context "with no subscriptions" do
      it "returns zero metrics" do
        result = service.calculate

        expect(result[:active_subscribers_at_start]).to eq(0)
        expect(result[:new_subscribers]).to eq(0)
        expect(result[:churned_subscribers]).to eq(0)
        expect(result[:customer_churn_rate]).to eq(0.0)
        expect(result[:retention_rate]).to eq(100.0)
      end
    end

    context "with active subscriptions" do
      before do
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
      end

      it "counts active subscriptions at start" do
        result = service.calculate
        expect(result[:active_subscribers_at_start]).to eq(2)
      end
    end

    context "with new subscriptions" do
      before do
        create(:subscription, link: product, user: create(:user), created_at: 15.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 5.days.ago)
      end

      it "counts new subscriptions during period" do
        result = service.calculate
        expect(result[:new_subscribers]).to eq(2)
      end
    end

    context "with churned subscriptions" do
      before do
        create(:subscription, link: product, user: create(:user),
               created_at: 60.days.ago, deactivated_at: 10.days.ago)
        create(:subscription, link: product, user: create(:user),
               created_at: 60.days.ago, deactivated_at: 5.days.ago)
      end

      it "counts churned subscriptions during period" do
        result = service.calculate
        expect(result[:churned_subscribers]).to eq(2)
      end
    end

    context "with mixed subscription activity" do
      before do
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 15.days.ago)
        create(:subscription, link: product, user: create(:user),
               created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      it "calculates churn rate using Stripe formula" do
        result = service.calculate

        expect(result[:active_subscribers_at_start]).to eq(3)
        expect(result[:new_subscribers]).to eq(1)
        expect(result[:churned_subscribers]).to eq(1)
        expect(result[:total_subscriber_base]).to eq(4)
        expect(result[:customer_churn_rate]).to eq(25.0)
      end

      it "calculates net subscriber change" do
        result = service.calculate
        expect(result[:net_subscriber_change]).to eq(0)
      end
    end

    context "with subscribers who join and churn in same period" do
      before do
        create(:subscription, link: product, user: create(:user),
               created_at: 15.days.ago, deactivated_at: 5.days.ago)
      end

      it "counts in both new and churned" do
        result = service.calculate

        expect(result[:new_subscribers]).to eq(1)
        expect(result[:churned_subscribers]).to eq(1)
        expect(result[:total_subscriber_base]).to eq(1)
        expect(result[:customer_churn_rate]).to eq(100.0)
      end
    end
  end

  describe "#calculate_by_date" do
    it "returns array of daily calculations" do
      start = 2.days.ago.to_date
      end_date = Date.current
      service = described_class.new(user: user, start_date: start, end_date: end_date)

      results = service.calculate_by_date

      expect(results).to be_an(Array)
      expect(results.length).to eq(3)
      expect(results.first).to have_key(:customer_churn_rate)
    end
  end

  describe "MRR calculations" do
    context "with monthly subscriptions" do
      let!(:price) { create(:price, link: product, price_cents: 1000, recurrence: "monthly") }
      let!(:subscription) { create(:subscription, link: product, user: create(:user), created_at: 15.days.ago) }

      before do
        payment_option = create(:payment_option, subscription: subscription, price: price)
        subscription.update!(last_payment_option: payment_option)
      end

      it "calculates MRR correctly for monthly subscriptions" do
        result = service.calculate
        expect(result[:new_mrr_cents]).to eq(1000)
      end
    end

    context "with yearly subscriptions" do
      let!(:price) { create(:price, link: product, price_cents: 12000, recurrence: "yearly") }
      let!(:subscription) { create(:subscription, link: product, user: create(:user), created_at: 15.days.ago) }

      before do
        payment_option = create(:payment_option, subscription: subscription, price: price)
        subscription.update!(last_payment_option: payment_option)
      end

      it "normalizes yearly to MRR" do
        result = service.calculate
        expect(result[:new_mrr_cents]).to eq(1000)
      end
    end
  end
end

