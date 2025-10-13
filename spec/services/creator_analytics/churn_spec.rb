# frozen_string_literal: true

require "spec_helper"

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

        expect(result[:churned_subscribers]).to eq(0)
        expect(result[:customer_churn_rate]).to eq(0.0)
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

        expect(result[:churned_subscribers]).to eq(1)
        expect(result[:customer_churn_rate]).to eq(25.0)
      end
    end

    context "with subscribers who join and churn in same period" do
      before do
        create(:subscription, link: product, user: create(:user),
               created_at: 15.days.ago, deactivated_at: 5.days.ago)
      end

      it "counts in both new and churned" do
        result = service.calculate

        expect(result[:churned_subscribers]).to eq(1)
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
      expect(results.first).to have_key(:churned_subscribers)
      expect(results.first).to have_key(:churned_mrr_cents)
    end
  end

  describe "#customer_churn_rate" do
    context "with active and churned subscriptions" do
      before do
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 60.days.ago)
        create(:subscription, link: product, user: create(:user), created_at: 15.days.ago)
        create(:subscription, link: product, user: create(:user),
               created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      it "calculates churn rate correctly" do
        expect(service.customer_churn_rate).to eq(25.0)
      end
    end
  end

  describe "MRR calculations" do
    context "with monthly subscriptions" do
      let!(:price) { create(:price, link: product, price_cents: 1000, recurrence: "monthly") }
      let!(:subscription) do
        create(:subscription, link: product, user: create(:user),
               created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      before do
        payment_option = create(:payment_option, subscription: subscription, price: price)
        subscription.update!(last_payment_option: payment_option)
      end

      it "calculates churned MRR correctly for monthly subscriptions" do
        result = service.calculate
        expect(result[:churned_mrr_cents]).to eq(1000)
      end
    end

    context "with yearly subscriptions" do
      let!(:price) { create(:price, link: product, price_cents: 12000, recurrence: "yearly") }
      let!(:subscription) do
        create(:subscription, link: product, user: create(:user),
               created_at: 60.days.ago, deactivated_at: 10.days.ago)
      end

      before do
        payment_option = create(:payment_option, subscription: subscription, price: price)
        subscription.update!(last_payment_option: payment_option)
      end

      it "normalizes yearly to MRR" do
        result = service.calculate
        expect(result[:churned_mrr_cents]).to eq(1000)
      end
    end
  end
end

