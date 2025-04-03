# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Products::OtherRefundPoliciesController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "#index" do
    let(:product) { create(:product, user: seller) }

    it_behaves_like "authorize called for action", :get, :index do
      let(:policy_klass) { LinkPolicy }
      let(:policy_method) { :edit? }
      let(:record) { product }
      let(:request_params) { { product_id: product.unique_permalink } }
      let(:request_format) { :json }
    end

    let!(:refund_policy) { create(:product_refund_policy, seller:, product:) }
    let!(:other_refund_policy_one) { create(:product_refund_policy, product: create(:product, user: seller), seller:) }
    let!(:other_refund_policy_two) { create(:product_refund_policy, product: create(:product, user: seller), seller:) }

    before do
      create(:product_refund_policy, product: create(:product, user: seller, archived: true), seller:)
      create(:product_refund_policy, product: create(:product, user: seller, deleted_at: Time.current), seller:)
    end

    it "returns an array of ordered refund policies for visible and not archived products" do
      get :index, params: { product_id: product.unique_permalink }, as: :json
      expect(response.parsed_body).to eq(
        [
          JSON.parse(other_refund_policy_two.to_json),
          JSON.parse(other_refund_policy_one.to_json),
        ]
      )
    end
  end
end
