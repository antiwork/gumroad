# frozen_string_literal: true

require "spec_helper"

describe Product::Caching do
  describe "#invalidate_cache" do
    before do
      @product = create(:product)
      Rails.cache.write(@product.scoped_cache_key("en"), "<html>hello</html>")
      @product.product_cached_values.create!

      @other_product = create(:product)
      Rails.cache.write(@other_product.scoped_cache_key("en"), "<html>hello</html>")
      @other_product.product_cached_values.create!
    end

    it "clears the correct cache" do
      expect(Rails.cache.read(@product.scoped_cache_key("en"))).to be_present
      expect(@product.reload.product_cached_values.fresh.size).to eq(1)

      expect(Rails.cache.read(@other_product.scoped_cache_key("en"))).to be_present
      expect(@other_product.reload.product_cached_values.fresh.size).to eq(1)

      @product.invalidate_cache

      expect(Rails.cache.read(@product.scoped_cache_key("en"))).to_not be_present
      expect(@product.reload.product_cached_values.fresh.size).to eq(0)

      expect(Rails.cache.read(@other_product.scoped_cache_key("en"))).to be_present
      expect(@other_product.reload.product_cached_values.fresh.size).to eq(1)
    end
  end

  describe ".scoped_cache_key" do
    let(:link) { create(:product) }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("guid")
    end

    it "returns no test path cache key if ab test is not assigned" do
      expect(link.scoped_cache_key("en")).to eq "#{link.id}_guid_en_displayed_switch_ids_"
    end

    it "returns a fragemented cache key if it is fragmented" do
      expect(link.scoped_cache_key("en", true)).to eq "#{link.id}_guid_en_fragmented_displayed_switch_ids_"
    end

    it "returns dynamic product page switch-aware cache key, with the right ordering" do
      expect(link.scoped_cache_key("en", true, [5, 2])).to eq "#{link.id}_guid_en_fragmented_displayed_switch_ids_2_5"
    end

    it "uses a prefetched_cache_key if given" do
      expect(link.scoped_cache_key("en", true, [5, 2], "prefetched")).to eq "prefetched_en_fragmented_displayed_switch_ids_2_5"
    end
  end

  describe "#scoped_cache_keys" do
    let(:links) { [create(:product), create(:product)] }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("guid")
    end

    it "returns a cache key for each given products" do
      keys = Product::Caching.scoped_cache_keys(links, [[], [5, 2]], "en", true)
      expect(keys[0]).to eq("#{links[0].id}_guid_en_fragmented_displayed_switch_ids_")
      expect(keys[1]).to eq("#{links[1].id}_guid_en_fragmented_displayed_switch_ids_2_5")
    end
  end

  describe ".dashboard_collection_data" do
    let(:product) { create(:product, max_purchase_count: 100) }

    [Redis::TimeoutError, RedisClient::ReadTimeoutError].each do |error_class|
      it "returns cached and live products when warming raises #{error_class}, then retries on the next read" do
        cached_product = create(:product)
        cached_value = cached_product.product_cached_values.create!
        collection = [cached_product, product]
        error = error_class.new("Redis unavailable")
        expect(CacheProductDataWorker).to receive(:perform_bulk).with([[product.id]]).and_raise(error)
        expect(ErrorNotifier).to receive(:notify).with(error, hash_including(source: "dashboard_cache_enqueue"))

        expect(described_class.dashboard_collection_data(collection, cache: true)).to eq([cached_value, product])

        allow(CacheProductDataWorker).to receive(:perform_bulk).and_call_original
        described_class.dashboard_collection_data(collection, cache: true)
        expect(CacheProductDataWorker).to have_enqueued_sidekiq_job(product.id)
      end
    end

    it "still yields live product data when reporting a failed warm also fails" do
      collection = [product]
      allow(CacheProductDataWorker).to receive(:perform_bulk).and_raise(RedisClient::ReadTimeoutError)
      allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "reporting unavailable")

      data = described_class.dashboard_collection_data(collection, cache: true) { |item| { "id" => item.id } }

      expect(data).to contain_exactly(hash_including("id" => product.id, "remaining_for_sale_count" => 100))
    end

    it "does not swallow programming errors from the cache enqueue" do
      collection = [product]
      allow(CacheProductDataWorker).to receive(:perform_bulk).and_raise(ArgumentError)

      expect { described_class.dashboard_collection_data(collection, cache: true) }.to raise_error(ArgumentError)
    end

    context "when no block is passed" do
      subject(:dashboard_collection_data) { described_class.dashboard_collection_data(collection, cache:) }

      context "when cache is true" do
        let(:cache) { true }

        context "when one product exists" do
          let(:collection) { [product] }

          context "when the product has no product_cached_value" do
            it "schedules a product cache worker and returns the product" do
              expect(dashboard_collection_data).to contain_exactly(product)
              expect(CacheProductDataWorker).to have_enqueued_sidekiq_job(product.id)
            end
          end

          context "when the product has a product_cached_value" do
            before do
              product.product_cached_values.create!
            end

            it "does not schedule a cache worker and returns the product cached value" do
              expect do
                expect(dashboard_collection_data).to contain_exactly(product.reload.product_cached_values.fresh.first)
              end.not_to change { CacheProductDataWorker.jobs.size }
            end
          end

          context "when the product has an expired product_cached_value" do
            before do
              product.product_cached_values.create!(expired: true)
            end

            it "schedules a product cache worker and returns the product" do
              expect(dashboard_collection_data).to contain_exactly(product)
              expect(CacheProductDataWorker).to have_enqueued_sidekiq_job(product.id)
            end
          end
        end

        context "when multiple products without cache exist" do
          let(:another_product) { create(:product) }
          let(:collection) { [product, another_product] }

          it "bulk inserts the product cache creation worker" do
            expect(CacheProductDataWorker).to receive(:perform_bulk).with([[product.id], [another_product.id]]).and_call_original
            dashboard_collection_data
          end

          context "when one product has a cached value" do
            before do
              product.product_cached_values.create!
            end

            it "returns the proper result" do
              expect(
                dashboard_collection_data
              ).to contain_exactly(product.reload.product_cached_values.fresh.first, another_product)
            end
          end
        end
      end

      context "when cache is false" do
        let(:cache) { false }

        context "when one product exists" do
          let(:collection) { [product] }

          context "when the product has no product_cached_value" do
            it "does not schedule a cache worker and returns the product" do
              expect do
                expect(dashboard_collection_data).to contain_exactly(product)
              end.not_to change { CacheProductDataWorker.jobs.size }
            end
          end

          context "when the product has a product_cached_value" do
            before do
              product.product_cached_values.create!
            end

            it "does not schedule a cache worker and returns the product cached value" do
              expect do
                expect(dashboard_collection_data).to contain_exactly(product.reload.product_cached_values.fresh.first)
              end.not_to change { CacheProductDataWorker.jobs.size }
            end
          end

          context "when the product has an expired product_cached_value" do
            before do
              product.product_cached_values.create!(expired: true)
            end

            it "does not schedule a cache worker and returns the product" do
              expect do
                expect(dashboard_collection_data).to contain_exactly(product)
              end.not_to change { CacheProductDataWorker.jobs.size }
            end
          end
        end

        context "when multiple products without cache exist" do
          let(:another_product) { create(:product) }
          let(:collection) { [product, another_product] }

          it "does not schedule a cache worker and returns the product" do
            expect do
              expect(dashboard_collection_data).to contain_exactly(product, another_product)
            end.not_to change { CacheProductDataWorker.jobs.size }
          end

          context "when one product has a cached value" do
            before do
              product.product_cached_values.create!
            end

            it "returns the proper result" do
              expect do
                expect(
                  dashboard_collection_data
                ).to contain_exactly(product.reload.product_cached_values.fresh.first, another_product)
              end.not_to change { CacheProductDataWorker.jobs.size }
            end
          end
        end
      end
    end

    context "when block is passed" do
      subject(:dashboard_collection_data) do
        described_class.dashboard_collection_data(collection, cache: true) { |product| { "id" => product.id } }
      end

      context "when one product exists" do
        let(:collection) { [product] }

        context "when the product has no product_cached_value" do
          it "schedules a product cache worker and yields the product metrics" do
            expect(dashboard_collection_data).to contain_exactly({
                                                                   "id" => product.id,
                                                                   "monthly_recurring_revenue" => 0.0,
                                                                   "remaining_for_sale_count" => 100,
                                                                   "revenue_pending" => 0.0,
                                                                   "successful_sales_count" => 0,
                                                                   "total_usd_cents" => 0,
                                                                 })
            expect(CacheProductDataWorker).to have_enqueued_sidekiq_job(product.id)
          end
        end

        context "when the product has a product_cached_value" do
          before do
            product.product_cached_values.create!
          end

          it "does not schedule a cache worker and returns the product cached value" do
            expect do
              expect(dashboard_collection_data).to contain_exactly({
                                                                     "id" => product.id,
                                                                     "monthly_recurring_revenue" => 0.0,
                                                                     "remaining_for_sale_count" => 100,
                                                                     "revenue_pending" => 0.0,
                                                                     "successful_sales_count" => 0,
                                                                     "total_usd_cents" => 0,
                                                                   })
            end.not_to change { CacheProductDataWorker.jobs.size }
          end
        end

        context "when the product has an expired product_cached_value" do
          before do
            product.product_cached_values.create!(expired: true)
          end

          it "schedules a product cache worker and returns the product" do
            expect(dashboard_collection_data).to contain_exactly({
                                                                   "id" => product.id,
                                                                   "monthly_recurring_revenue" => 0.0,
                                                                   "remaining_for_sale_count" => 100,
                                                                   "revenue_pending" => 0.0,
                                                                   "successful_sales_count" => 0,
                                                                   "total_usd_cents" => 0,
                                                                 })
            expect(CacheProductDataWorker).to have_enqueued_sidekiq_job(product.id)
          end
        end

        context "when Elasticsearch is unavailable" do
          it "returns default values instead of raising" do
            allow(product).to receive(:successful_sales_count).and_raise(
              Elasticsearch::Transport::Transport::Errors::NotFound.new("[404] no such index [purchases]")
            )

            result = described_class.dashboard_collection_data([product], cache: true) { |p| { "id" => p.id } }

            expect(result).to contain_exactly({
                                                "id" => product.id,
                                                "monthly_recurring_revenue" => 0.0,
                                                "remaining_for_sale_count" => 100,
                                                "revenue_pending" => product.revenue_pending.to_f,
                                                "successful_sales_count" => 0,
                                                "total_usd_cents" => 0.0,
                                              })
          end
        end
      end

      context "when multiple products exist" do
        let(:another_product) { create(:product) }
        let(:collection) { [product, another_product] }

        it "bulk inserts the product cache creation worker" do
          expect(CacheProductDataWorker).to receive(:perform_bulk).with([[product.id], [another_product.id]]).and_call_original
          dashboard_collection_data
        end

        it "returns the proper result" do
          expect(dashboard_collection_data).to contain_exactly(
            {
              "id" => product.id,
              "monthly_recurring_revenue" => 0.0,
              "remaining_for_sale_count" => 100,
              "revenue_pending" => 0.0,
              "successful_sales_count" => 0,
              "total_usd_cents" => 0,
            },
            {
              "id" => another_product.id,
              "monthly_recurring_revenue" => 0.0,
              "remaining_for_sale_count" => nil,
              "revenue_pending" => 0.0,
              "successful_sales_count" => 0,
              "total_usd_cents" => 0,
            }
          )
        end
      end
    end
  end
end
