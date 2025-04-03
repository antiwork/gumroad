# frozen_string_literal: true

describe CustomersPresenter do
  let(:seller) { create(:named_seller, :eligible_for_service_products, notification_endpoint: "http://local/host") }
  let(:product) { create(:product, user: seller, name: "Product", price_cents: 100) }
  let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: seller, name: "Membership", is_multiseat_license: true) }
  let(:coffee) { create(:coffee_product, user: seller, name: "Coffee") }
  let(:offer_code) { create(:offer_code, code: "code", products: [membership]) }
  let(:purchase1) { create(:purchase, link: product, full_name: "Customer 1", email: "customer1@gumroad.com", created_at: 1.day.ago, seller:, was_product_recommended: true, recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION, is_purchasing_power_parity_discounted: true, ip_country: "United States", is_additional_contribution: true, can_contact: false) }
  let(:purchase2) { create(:membership_purchase, link: membership, full_name: "Customer 2", email: "customer2@gumroad.com", purchaser: create(:user), created_at: 2.days.ago, seller:, is_original_subscription_purchase: true, offer_code:, is_gift_sender_purchase: true, affiliate: create(:direct_affiliate), is_preorder_authorization: true, preorder: create(:preorder)) }
  let(:purchase3) { create(:purchase, link: coffee, variant_attributes: [coffee.alive_variants.first]) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:presenter) { described_class.new(pundit_user:, customers: [purchase1, purchase2], pagination: nil, count: 2) }

  before do
    purchase1.create_purchasing_power_parity_info!(factor: 0.5)
    create(:gift, giftee_email: "giftee@gumroad.com", giftee_purchase: create(:purchase), gifter_purchase: purchase2)
    purchase2.reload
    create(:upsell_purchase, purchase: purchase1, upsell: create(:upsell, seller:, product:, cross_sell: true))
    create(:variant, name: nil, variant_category: coffee.variant_categories_alive.first, price_difference_cents: 100)
  end

  describe "#customers_props" do
    it "returns the correct props" do
      expect(presenter.customers_props).to eq(
        {
          customers: [purchase1, purchase2].map { CustomerPresenter.new(purchase: _1).customer(pundit_user:) },
          count: 2,
          pagination: nil,
          product_id: nil,
          products: [
            {
              id: product.external_id,
              name: "Product",
              variants: [],
            },
            {
              id: membership.external_id,
              name: "Membership",
              variants: [
                {
                  id: membership.alive_variants.first.external_id,
                  name: "First Tier"
                },
                {
                  id: membership.alive_variants.second.external_id,
                  name: "Second Tier"
                }
              ],
            },
            {
              id: coffee.external_id,
              name: "Coffee",
              variants: [
                {
                  id: coffee.alive_variants.first.external_id,
                  name: "",
                },
                {
                  id: coffee.alive_variants.second.external_id,
                  name: "",
                },
              ],
            },
          ],
          countries: Compliance::Countries.for_select.map(&:last),
          currency_type: "usd",
          can_ping: true,
          show_refund_fee_notice: false,
        }
      )
    end
  end

  describe "variant belongs to coffee" do
    let(:seller) { create(:user, :eligible_for_service_products) }
    let(:coffee) { create(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE) }
    let(:variant_category) { create(:variant_category, link: coffee) }

    context "name is blank" do
      it "does not add an error" do
        variant = build(:variant, variant_category:, price_difference_cents: 100)  # Add a valid price
        expect(variant).to be_valid
      end
    end

    context "price is zero" do
      it "adds an error" do
        variant = build(:variant, variant_category:, price_difference_cents: 0)
        expect(variant).not_to be_valid
        expect(variant.errors.full_messages).to include("Price difference cents must be greater than 0")
      end
    end
  end
end
