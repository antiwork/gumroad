# frozen_string_literal: true

describe Checkout::DiscountsPresenter do
  include CurrencyHelper

  let(:seller) { create(:named_seller) }
  let(:product1) { create(:product, user: seller, price_cents: 1000, price_currency_type: Currency::EUR) }
  let(:product2) { create(:product, user: seller, price_cents: 500) }
  let!(:product3) { create(:membership_product_with_preset_tiered_pricing, user: seller) }
  let!(:offer_code1) { create(:percentage_offer_code, name: "Discount 1", code: "code1", products: [product1, product2], user: seller, max_purchase_count: 12, valid_at: ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year - 1}"), expires_at: ActiveSupport::TimeZone[seller.timezone].parse("February 1 #{Time.current.year - 1}"), minimum_quantity: 1, duration_in_billing_cycles: 1, minimum_amount_cents: 1000) }
  let!(:offer_code2) { create(:offer_code, name: "Discount 2", code: "code2", products: [product2], user: seller, max_purchase_count: 20, amount_cents: 200, valid_at: ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year + 1}")) }
  let(:offer_code3) { create(:percentage_offer_code, name: "Discount 3", code: "code3", universal: true, products: [], user: seller, amount_percentage: 50) }
  let(:user) { create(:user) }
  let(:presenter) { described_class.new(pundit_user: SellerContext.new(user:, seller:), offer_codes: [offer_code1, offer_code2, offer_code3], pagination: nil) }

  describe "#discounts_props" do
    before do
      create(:product, user: seller, deleted_at: Time.current)
      create_list(:purchase, 10, link: product1, offer_code: offer_code1, displayed_price_currency_type: Currency::EUR, price_cents: get_usd_cents(Currency::EUR, product1.price_cents))
      create_list(:purchase, 5, link: product2, offer_code: offer_code2)
      create(:purchase, link: product1, offer_code: offer_code3)
      create(:purchase, link: product2, offer_code: offer_code3)
    end

    it "returns the correct props" do
      create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)

      expect(presenter.discounts_props)
        .to eq({
                 pages: ["discounts", "form", "upsells"],
                 pagination: nil,
                 offer_codes: [
                   {
                     can_update: true,
                     discount: { type: "percent", value: 50 },
                     code: "code1",
                     currency_type: "usd",
                     id: offer_code1.external_id,
                     name: "Discount 1",
                     valid_at: offer_code1.valid_at,
                     expires_at: offer_code1.expires_at,
                     limit: 12,
                     minimum_quantity: 1,
                     duration_in_billing_cycles: 1,
                     minimum_amount_cents: 1000,
                     products: [
                       {
                         id: product1.external_id,
                         name: "The Works of Edgar Gumstein",
                         archived: false,
                         currency_type: "eur",
                         url: product1.long_url,
                         is_tiered_membership: false,
                         is_recurring_billing: false,
                       },
                       {
                         id: product2.external_id,
                         name: "The Works of Edgar Gumstein",
                         archived: false,
                         currency_type: "usd",
                         url: product2.long_url,
                         is_tiered_membership: false,
                         is_recurring_billing: false,
                       },
                     ],
                   },
                   {
                     can_update: true,
                     discount: { type: "cents", value: 200 },
                     code: "code2",
                     currency_type: "usd",
                     id: offer_code2.external_id,
                     name: "Discount 2",
                     valid_at: offer_code2.valid_at,
                     expires_at: nil,
                     limit: 20,
                     minimum_quantity: nil,
                     duration_in_billing_cycles: nil,
                     minimum_amount_cents: nil,
                     products: [
                       {
                         id: product2.external_id,
                         name: "The Works of Edgar Gumstein",
                         archived: false,
                         currency_type: "usd",
                         url: product2.long_url,
                         is_tiered_membership: false,
                         is_recurring_billing: false,
                       },
                     ],
                   },
                   {
                     can_update: true,
                     discount: { type: "percent", value: 50 },
                     code: "code3",
                     currency_type: "usd",
                     id: offer_code3.external_id,
                     name: "Discount 3",
                     valid_at: nil,
                     expires_at: nil,
                     limit: nil,
                     minimum_quantity: nil,
                     duration_in_billing_cycles: nil,
                     minimum_amount_cents: nil,
                     products: nil,
                   },
                 ],
                 products: [
                   {
                     id: product3.external_id,
                     name: "The Works of Edgar Gumstein",
                     archived: false,
                     currency_type: "usd",
                     url: product3.long_url,
                     is_tiered_membership: true,
                     is_recurring_billing: true,
                   },
                   {
                     id: product1.external_id,
                     name: "The Works of Edgar Gumstein",
                     archived: false,
                     currency_type: "eur",
                     url: product1.long_url,
                     is_tiered_membership: false,
                     is_recurring_billing: false,
                   },
                   {
                     id: product2.external_id,
                     name: "The Works of Edgar Gumstein",
                     archived: false,
                     currency_type: "usd",
                     url: product2.long_url,
                     is_tiered_membership: false,
                     is_recurring_billing: false,
                   },
                 ],
                 show_black_friday_banner: false,
                 black_friday_code: "BLACKFRIDAY2025",
                 black_friday_code_name: "Black Friday 2025",
               })
    end
  end

  describe "#offer_code_props" do
    context "with user as admin for owner" do
      before do
        create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)
      end

      it "returns the correct props" do
        expect(presenter.offer_code_props(offer_code1)).to eq(
          {
            can_update: true,
            discount: { type: "percent", value: 50 },
            code: "code1",
            currency_type: "usd",
            id: offer_code1.external_id,
            name: "Discount 1",
            valid_at: offer_code1.valid_at,
            expires_at: offer_code1.expires_at,
            limit: 12,
            minimum_quantity: 1,
            duration_in_billing_cycles: 1,
            minimum_amount_cents: 1000,
            products: [
              {
                id: product1.external_id,
                name: "The Works of Edgar Gumstein",
                archived: false,
                currency_type: "eur",
                url: product1.long_url,
                is_tiered_membership: false,
                is_recurring_billing: false,
              },
              {
                id: product2.external_id,
                name: "The Works of Edgar Gumstein",
                archived: false,
                currency_type: "usd",
                url: product2.long_url,
                is_tiered_membership: false,
                is_recurring_billing: false,
              },
            ],
          }
        )
      end
    end

    [TeamMembership::ROLE_ADMIN, TeamMembership::ROLE_MARKETING].each do |role|
      context "with user as #{role} for owner" do
        before do
          create(:team_membership, user:, seller:, role:)
        end

        it "returns correct props" do
          expect(presenter.offer_code_props(offer_code1)[:can_update]).to eq(true)
        end
      end
    end

    [TeamMembership::ROLE_ACCOUNTANT, TeamMembership::ROLE_SUPPORT].each do |role|
      context "with user as #{role} for owner" do
        before do
          create(:team_membership, user:, seller:, role:)
        end

        it "returns correct props" do
          expect(presenter.offer_code_props(offer_code1)[:can_update]).to eq(false)
        end
      end
    end
  end
end
