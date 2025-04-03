# frozen_string_literal: true

describe AnalyticsPresenter do
  let(:seller) { create(:user) }
  let(:presenter) { described_class.new(seller:) }

  let!(:alive_product) { create(:product, user: seller) }
  let!(:deleted_with_sales) { create(:product, user: seller, deleted_at: Time.current) }
  let!(:deleted_without_sales) { create(:product, user: seller, deleted_at: Time.current) }

  before { create(:purchase, link: deleted_with_sales) }

  describe "#page_props" do
    it "returns the correct props" do
      expect(presenter.page_props[:products]).to contain_exactly(
        {
          id: alive_product.external_id,
          alive: true,
          unique_permalink: alive_product.unique_permalink,
          name: alive_product.name
        }, {
          id: deleted_with_sales.external_id,
          alive: false,
          unique_permalink: deleted_with_sales.unique_permalink,
          name: deleted_with_sales.name
        }
      )
      expect(presenter.page_props[:country_codes]).to include("United States" => "US")
      expect(presenter.page_props[:state_names].first).to eq("Alabama")
      expect(presenter.page_props[:state_names].last).to eq("Other")
    end
  end
end
