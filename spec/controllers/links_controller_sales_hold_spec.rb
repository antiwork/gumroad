# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:admin) { create(:admin_user) }
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  before { sign_in seller }

  describe "POST publish" do
    it "refuses a product Gumroad has put on a sales hold" do
      product.hold_sales!(seller:, held_by: admin)

      post :publish, params: { id: product.unique_permalink }

      expect(response.parsed_body).to eq({ success: false, error_message: Link::UNPUBLISHED_BY_ADMIN_MESSAGE }.as_json)
      expect(product.reload.purchase_disabled_at).to be_present
    end

    it "publishes the product once the hold is released" do
      hold, = product.hold_sales!(seller:, held_by: admin)
      product.reload.release_sales_hold!(hold, seller:, released_by: admin)

      post :publish, params: { id: product.unique_permalink }

      expect(response.parsed_body["success"]).to be(true)
      expect(product.reload).to be_published
    end
  end
end
