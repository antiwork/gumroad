# frozen_string_literal: true

describe Checkout::FormPresenter do
  describe "#form_props" do
    let(:seller) { create(:named_seller) }
    let(:user) { create(:user) }
    let(:presenter) { described_class.new(pundit_user: SellerContext.new(user:, seller:)) }

    before do
      create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)
    end

    it "returns the correct props" do
      expect(presenter.form_props)
        .to eq(
          {
            pages: ["discounts", "form", "upsells"],
            user: {
              display_offer_code_field: false,
              recommendation_type: User::RecommendationType::OWN_PRODUCTS,
              tipping_enabled: false,
            },
            cart_item: nil,
            card_product: nil,
            custom_fields: [],
            products: [],
          }
        )
    end

    context "when tipping is enabled for the user" do
      before do
        seller.update!(tipping_enabled: true)
      end

      it "returns true for tipping_enabled" do
        expect(presenter.form_props[:user][:tipping_enabled]).to eq(true)
      end
    end

    context "when the seller has the offer code field enabled" do
      before do
        seller.update!(display_offer_code_field: true)
      end

      it "returns the correct props" do
        expect(presenter.form_props[:user][:display_offer_code_field]).to eq(true)
      end
    end

    context "when the seller has an alive product" do
      let!(:product) { create(:product, user: seller) }

      it "includes it as a cart item, card product, and in the list of products" do
        props = presenter.form_props
        expect(props[:cart_item]).to eq(CheckoutPresenter.new(logged_in_user: nil, ip: nil).checkout_product(product, product.cart_item({}), {}).merge({ quantity: 1, url_parameters: {}, referrer: "" }))
        expect(props[:card_product]).to eq(ProductPresenter.card_for_web(product:))
        expect(props[:products]).to eq [{ id: product.external_id, name: product.name, archived: false }]
      end
    end

    context "when the seller has custom fields" do
      it "returns the correct props" do
        product = create(:product)
        field = create(:custom_field, seller:, products: [product])
        other_product = create(:product, user: seller, json_data: { custom_fields: [{ type: "text", name: "Field", required: true }] })
        other_field = create(:custom_field, seller:, products: [other_product])
        create(:custom_field, seller:, is_post_purchase: true)
        expect(presenter.form_props[:custom_fields]).to eq [
          { id: field.external_id, name: field.name, global: false, required: false, collect_per_product: false, type: field.type, products: [product.external_id] },
          { id: other_field.external_id, name: other_field.name, global: false, required: false, collect_per_product: false, type: other_field.type, products: [other_product.external_id] }
        ]
      end
    end
  end
end
