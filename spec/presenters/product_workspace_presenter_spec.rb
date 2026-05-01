# frozen_string_literal: true

require "spec_helper"

describe ProductWorkspacePresenter do
  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:rich_content_description) { [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "hello" }] }] }

  def props_for(product)
    described_class.new(product:, pundit_user:).props
  end

  describe "#props" do
    it "returns product subset, readiness, sections, and settings_payments_url" do
      product = create(:product, user: seller, name: "live one", price_cents: 1000)
      props = props_for(product)

      expect(props[:product]).to include(
        "id" => product.id,
        "name" => "live one",
        "native_type" => product.native_type,
        "permalink" => product.unique_permalink,
        "edit_url" => Rails.application.routes.url_helpers.edit_link_path(product),
      )
      expect(props[:readiness]).to eq("state" => "live", "missing" => [])
      expect(props[:sections]).to include("basics" => true)
      expect(props[:settings_payments_url]).to eq(Rails.application.routes.url_helpers.settings_payments_path)
    end
  end

  describe "section completion" do
    it "marks basics complete when the product is saved with a name" do
      product = create(:product, user: seller, name: "draft one", draft: true)
      expect(props_for(product)[:sections]["basics"]).to be(true)
    end

    it "marks offer incomplete when content or cover are missing" do
      product = create(:product, user: seller, name: "no content", price_cents: 1000, draft: true)
      expect(props_for(product)[:sections]["offer"]).to be(false)
    end

    it "marks offer complete when price, content, and cover are all present" do
      product = create(:product, user: seller, name: "ready", price_cents: 1000, draft: true)
      create(:rich_content, entity: product, description: rich_content_description)
      create(:thumbnail, product:)

      expect(props_for(product.reload)[:sections]["offer"]).to be(true)
    end

    it "treats free products with price_cents 0 as having a complete offer" do
      product = create(:product, user: seller, name: "free", price_cents: 0, draft: true)
      create(:rich_content, entity: product, description: rich_content_description)
      create(:thumbnail, product:)

      expect(props_for(product.reload)[:sections]["offer"]).to be(true)
    end

    it "marks payments complete when the seller can publish products" do
      product = create(:product, user: seller, name: "ok", price_cents: 1000)
      expect(props_for(product)[:sections]["payments"]).to be(true)
    end

    it "marks payments incomplete when the seller has no payment setup" do
      seller.update!(payment_address: nil)
      product = create(:product, user: seller, name: "needs payment", price_cents: 1000, draft: true)

      expect(props_for(product)[:sections]["payments"]).to be(false)
    end
  end

  describe "readiness" do
    it "returns nil for membership / recurring billing products while still deriving sections" do
      product = create(:membership_product, user: seller, name: "membership")
      props = props_for(product)

      expect(props[:readiness]).to be_nil
      expect(props[:sections]).to include("basics", "offer", "payments")
    end
  end
end
