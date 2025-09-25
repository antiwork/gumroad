# frozen_string_literal: true

describe Checkout::UpsellsPresenter do
  describe "#upsells_props" do
    let(:seller) { create(:named_seller) }
    let(:product1) { create(:product_with_digital_versions, user: seller, price_cents: 1000) }
    let(:product2) { create(:product_with_digital_versions, user: seller, price_cents: 500) }
    let!(:upsell1) { create(:upsell, product: product1, variant: product1.alive_variants.second, name: "Upsell 1", seller:, cross_sell: true, replace_selected_products: true) }
    let!(:upsell2) { create(:upsell, product: product2, offer_code: create(:offer_code, products: [product2], user: seller), name: "Upsell 2", seller:) }
    let!(:upsell2_variant) { create(:upsell_variant, upsell: upsell2, selected_variant: product2.alive_variants.first, offered_variant: product2.alive_variants.second) }
    let(:presenter) { described_class.new(pundit_user: SellerContext.new(user: seller, seller:), upsells: seller.upsells.order(updated_at: :desc), pagination: nil) }
    let(:checkout_presenter) { CheckoutPresenter.new(logged_in_user: seller, ip: nil) }

    before do
      create(:product, user: seller, deleted_at: Time.current)

      build_list :product, 5 do |product, i|
        product.name = "Product #{i}"
        create_list(:upsell_purchase, 2, upsell: upsell1, selected_product: product)
        upsell1.selected_products << product
      end

      create_list(:upsell_purchase, 20, upsell: upsell2, selected_product: product2, upsell_variant: upsell2_variant)
    end

    it "returns the correct props" do
      expect(presenter.upsells_props)
        .to eq({
                 pages: ["discounts", "form", "upsells"],
                 pagination: nil,
                 upsells: [
                   {
                     description: "This offer will only last for a few weeks.",
                     id: upsell2.external_id,
                     name: "Upsell 2",
                     text: "Take advantage of this excellent offer!",
                     cross_sell: false,
                     replace_selected_products: false,
                     universal: false,
                     paused: false,
                     discount: {
                       cents: 100,
                       product_ids: [product2.external_id],
                       type: "fixed",
                       expires_at: nil,
                       minimum_quantity: nil,
                       duration_in_billing_cycles: nil,
                       minimum_amount_cents: nil,
                     },
                     product: {
                       id: product2.external_id,
                       currency_type: "usd",
                       name: "The Works of Edgar Gumstein",
                       variant: nil,
                     },
                     selected_products: [],
                     upsell_variants: [{
                       id: upsell2_variant.external_id,
                       selected_variant: {
                         id: upsell2_variant.selected_variant.external_id,
                         name: upsell2_variant.selected_variant.name,
                       },
                       offered_variant: {
                         id: upsell2_variant.offered_variant.external_id,
                         name: upsell2_variant.offered_variant.name
                       },
                     }],
                   },
                   {
                     description: "This offer will only last for a few weeks.",
                     id: upsell1.external_id,
                     name: "Upsell 1",
                     text: "Take advantage of this excellent offer!",
                     cross_sell: true,
                     replace_selected_products: true,
                     universal: false,
                     paused: false,
                     discount: nil,
                     product: {
                       id: product1.external_id,
                       currency_type: "usd",
                       name: "The Works of Edgar Gumstein",
                       variant: {
                         id: product1.alive_variants.second.external_id,
                         name: "Untitled 2",
                       },
                     },
                     selected_products: [
                       { id: upsell1.selected_products[0].external_id, name: "Product 0" },
                       { id: upsell1.selected_products[1].external_id, name: "Product 1" },
                       { id: upsell1.selected_products[2].external_id, name: "Product 2" },
                       { id: upsell1.selected_products[3].external_id, name: "Product 3" },
                       { id: upsell1.selected_products[4].external_id, name: "Product 4" },
                     ],
                     upsell_variants: [],
                   },
                 ],
                 products: [
                   {
                     id: product1.external_id,
                     name: product1.name,
                     has_multiple_versions: true,
                     native_type: product1.native_type
                   },
                   {
                     id: product2.external_id,
                     name: product2.name,
                     has_multiple_versions: true,
                     native_type: product2.native_type
                   }
                 ]
               })
    end
  end
end
