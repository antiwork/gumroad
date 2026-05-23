# frozen_string_literal: true

require "test_helper"

class RefreshSitemapMonthlyWorkerTest < ActiveSupport::TestCase
  self.described_class = RefreshSitemapMonthlyWorker



  context_ RefreshSitemapMonthlyWorker do
  context_ "#perform" do
  test "enqueues jobs to generate sitemaps for products updated in last month" do
        product_1 = create(:product, created_at: 3.months.ago, updated_at: 1.month.ago)
        product_2 = create(:product, created_at: 2.months.ago, updated_at: 1.month.ago)
        described_class.new.perform

        expect(RefreshSitemapDailyWorker).to have_enqueued_sidekiq_job(product_1.created_at.beginning_of_month.to_date.to_s)
        expect(RefreshSitemapDailyWorker).to have_enqueued_sidekiq_job(product_2.created_at.beginning_of_month.to_date.to_s).in(30.minutes)
      end

  test "doesn't enqueue jobs to generate sitemaps updated in the current month" do
        create(:product)

        described_class.new.perform

        expect(RefreshSitemapDailyWorker.jobs.size).to eq(0)
      end
    end
  end
end
