# frozen_string_literal: true

describe PaginatedProductPostsPresenter do
  describe "#index_props" do
    let(:product) { create(:product) }
    let!(:seller_post_for_customers_of_all_products) { create(:seller_post, seller: product.user, published_at: 3.hours.ago) }
    let!(:product_workflow_post) { create(:workflow_installment, workflow: create(:product_workflow, seller: product.user, link: product, published_at: 1.day.ago, bought_products: [product.unique_permalink]), link: product, published_at: 1.day.ago, bought_products: [product.unique_permalink]) }
    let(:options) { {} }
    let(:presenter) { described_class.new(product:, variant_external_id: nil, options:) }

    before do
      stub_const("#{described_class}::PER_PAGE", 1)
    end

    context "when 'page' option is not specified" do
      it "returns paginated posts for the first page" do
        result = presenter.index_props

        expect(result[:total]).to eq(2)
        expect(result[:next_page]).to eq(2)
        expect(result[:posts].size).to eq(1)
        expect(result[:posts].first).to eq(
          id: product_workflow_post.external_id,
          name: product_workflow_post.name,
          date: { type: "workflow_email_rule", time_duration: product_workflow_post.installment_rule.displayable_time_duration, time_period: product_workflow_post.installment_rule.time_period },
          url: product_workflow_post.full_url
        )
      end
    end

    context "when 'page' option is specified" do
      let(:options) { { page: 2 } }

      it "returns paginated posts for the specified page" do
        result = presenter.index_props

        expect(result[:total]).to eq(2)
        expect(result[:next_page]).to be_nil
        expect(result[:posts].size).to eq(1)
        expect(result[:posts].first).to eq(
          id: seller_post_for_customers_of_all_products.external_id,
          name: seller_post_for_customers_of_all_products.name,
          date: { type: "date", value: seller_post_for_customers_of_all_products.published_at },
          url: seller_post_for_customers_of_all_products.full_url
        )
      end
    end

    context "when the specified 'page' option is an overflowing page number" do
      let(:options) { { page: 3 } }

      it "raises an exception" do
        expect do
          presenter.index_props
        end.to raise_error(Pagy::OverflowError)
      end
    end
  end
end
