# frozen_string_literal: true

require "spec_helper"

describe RefreshSitemapDailyWorker do
  describe "#perform" do
    # The file path comes from the product's month and the worker reads Date.current; both must see one month.
    around { |example| freeze_time { example.run } }

    before do
      @product = create(:product, created_at: Time.current)
    end

    it "generates the sitemap" do
      date = @product.created_at
      sitemap_file_path = "#{Rails.public_path}/sitemap/products/monthly/#{date.year}/#{date.month}/sitemap.xml.gz"
      # Other specs write this month's file too, and nothing cleans public/sitemap.
      FileUtils.rm_f(sitemap_file_path)

      described_class.new.perform

      expect(File.exist?(sitemap_file_path)).to be true
    end

    # Regenerating a month overwrites its file, so retrying costs nothing and a killed run
    # would otherwise leave that month frozen with nothing recorded (gumroad-private#1679).
    it "retries a failed run" do
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end

    # A run that starts while another sitemap generation holds the shared
    # SitemapGenerator::Sitemap config would write its products into that run's path.
    it "re-enqueues itself when another sitemap generation is already running" do
      service = instance_double(SitemapService)
      allow(SitemapService).to receive(:new).and_return(service)
      expect(service).to receive(:generate).with("2026-08-01").and_raise(SitemapService::GenerationInProgress)

      described_class.new.perform("2026-08-01")

      expect(described_class).to have_enqueued_sidekiq_job("2026-08-01").in(SitemapService::GENERATION_RETRY_DELAY)
    end
  end
end
