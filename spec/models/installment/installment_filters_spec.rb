# frozen_string_literal: true

require "spec_helper"
require "shared_examples/with_filtering_support"

describe "InstallmentFilters"  do
  before do
    @creator = create(:named_user, :with_avatar)
    @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
  end

  describe "#add_and_validate_filters" do
    let(:user) { create(:user) }
    let!(:product) { create(:product, user:) }

    subject(:add_and_validate_filters) { filterable_object.add_and_validate_filters(params, user) }

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "product" do
      let(:filterable_object) { create(:product_installment, seller: user, link: product) }
    end

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "variant" do
      let(:filterable_object) { create(:variant_installment, seller: user, link: product) }
    end

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "seller" do
      let(:filterable_object) { create(:seller_installment, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "audience" do
      let(:filterable_object) { create(:audience_installment, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "follower" do
      let(:filterable_object) { create(:follower_installment, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "affiliate" do
      let(:filterable_object) { create(:affiliate_installment, seller: user, link: product) }
    end
  end
end
