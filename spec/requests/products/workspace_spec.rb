# frozen_string_literal: true

require "spec_helper"

describe "Products workspace", type: :request do
  let(:seller) { create(:named_seller) }

  describe "GET /products/:id/workspace" do
    let(:product) { create(:product, user: seller, name: "test product") }

    it "renders the workspace Inertia page for the owning seller" do
      sign_in seller

      get workspace_link_path(product), headers: { "X-Inertia" => "true" }

      expect(response).to be_successful
    end

    it "denies access to a different seller" do
      other_seller = create(:user)
      sign_in other_seller

      get workspace_link_path(product)

      expect(response).not_to be_successful
    end
  end

  describe "POST /products" do
    let(:link_params) do
      {
        link: {
          name: "Brand new product",
          price_range: "5",
          price_currency_type: "usd",
          native_type: "digital",
          is_physical: false,
          is_recurring_billing: false,
          subscription_duration: nil,
          description: nil,
          custom_summary: nil,
          ai_prompt: "",
          number_of_content_pages: nil,
          release_at_date: 1.day.from_now.to_date.to_s,
        },
      }
    end

    before { sign_in seller }

    it "redirects first-time sellers to the product workspace" do
      expect(seller.products.count).to eq(0)

      post links_path, params: link_params

      created = seller.products.last
      expect(response).to redirect_to(workspace_link_path(created))
    end

    it "redirects returning sellers to the legacy editor" do
      create(:product, user: seller, name: "Existing product")

      post links_path, params: link_params

      created = seller.products.where.not(name: "Existing product").last
      expect(response).to redirect_to(edit_link_path(created))
    end
  end
end
