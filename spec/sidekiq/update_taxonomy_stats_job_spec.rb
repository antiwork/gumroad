# frozen_string_literal: true

require "spec_helper"

describe UpdateTaxonomyStatsJob do
  describe "#perform" do
    it "updates the taxonomy stats" do
      recreate_model_index(Purchase)
      product_1 = create(:product, taxonomy: Taxonomy.find_by_path(["3d", "3d-modeling"]))
      product_2 = create(:product, taxonomy: Taxonomy.find_by_path(["3d", "vrchat", "tools"]), user: product_1.user)
      product_3 = create(:product, taxonomy: Taxonomy.find_by_path(["films", "movie", "anime"]))
      product_4 = create(:product, taxonomy: Taxonomy.find_by_path(["films", "movie", "horror"]))

      create(:purchase, link: product_1)
      create_list(:purchase, 2, link: product_2)
      create(:purchase, link: product_3)
      create_list(:purchase, 3, link: product_4, created_at: 90.days.ago)

      index_model_records(Purchase)

      described_class.new.perform

      stat_1 = TaxonomyStat.find_by(taxonomy: Taxonomy.find_by_path(["3d"]))
      expect(stat_1.sales_count).to eq(3)
      expect(stat_1.creators_count).to eq(1)
      expect(stat_1.products_count).to eq(2)
      expect(stat_1.recent_sales_count).to eq(3)

      stat_2 = TaxonomyStat.find_by(taxonomy: Taxonomy.find_by_path(["films"]))
      expect(stat_2.sales_count).to eq(4)
      expect(stat_2.creators_count).to eq(2)
      expect(stat_2.products_count).to eq(2)
      expect(stat_2.recent_sales_count).to eq(1)

      stat_3 = TaxonomyStat.find_by(taxonomy: Taxonomy.find_by_path(["education"]))
      expect(stat_3.sales_count).to eq(0)
      expect(stat_3.creators_count).to eq(0)
      expect(stat_3.products_count).to eq(0)
      expect(stat_3.recent_sales_count).to eq(0)
    end
  end
end
