# frozen_string_literal: true

require "spec_helper"

describe User::AffiliatedProducts, :vcr do
  describe "#directly_affiliated_products" do
    let(:affiliate_user) { create(:affiliate_user) }
    let(:creator_one) { create(:named_user) }
    let(:creator_two) { create(:named_user) }
    let!(:product_one) { create(:product, name: "Product 1", user: creator_one) }
    let!(:product_two) { create(:product, name: "Product 2", user: creator_one) }
    let!(:product_three) { create(:product, name: "Product 3", deleted_at: DateTime.current, user: creator_one) }
    let!(:product_four) { create(:product, name: "Product 4", user: creator_two) }
    let!(:product_five) { create(:product, name: "Product 5", user: creator_two) }
    let!(:product_six) { create(:product, name: "Product 6", user: creator_two) }
    let!(:product_seven) { create(:product, name: "Product 7", user: creator_two) }
    let!(:product_eight) { create(:product, name: "Product 8") }
    let!(:direct_affiliate_one) { create(:direct_affiliate, affiliate_user:, seller: creator_one, affiliate_basis_points: 1500, products: [product_one, product_two, product_three]) }
    let!(:direct_affiliate_two) { create(:direct_affiliate, affiliate_user:, seller: creator_two, affiliate_basis_points: 1000, products: [product_four], deleted_at: DateTime.current) }
    let!(:direct_affiliate_three) { create(:direct_affiliate, affiliate_user:, seller: creator_two, affiliate_basis_points: 500, products: [product_five, product_six, product_seven]) }
    let!(:purchase_one) { create(:purchase_in_progress, seller: creator_one, link: product_one, affiliate: direct_affiliate_one) }
    let!(:purchase_two) { create(:purchase_in_progress, seller: creator_one, link: product_one, affiliate: direct_affiliate_one, chargeable: create(:chargeable)) }
    let!(:purchase_three) { create(:purchase_in_progress, seller: creator_one, link: product_three, affiliate: direct_affiliate_one) }
    let!(:purchase_four) { create(:purchase_in_progress, seller: creator_two, link: product_four, affiliate: direct_affiliate_two) }
    let!(:purchase_five) { create(:purchase_in_progress, seller: creator_two, link: product_six, affiliate: direct_affiliate_three) }
    let!(:purchase_six) { create(:purchase_in_progress, seller: creator_two, link: product_six, affiliate: direct_affiliate_three) }
    let!(:purchase_seven) { create(:purchase_in_progress, link: product_eight) }
    let(:select_columns) { "name, affiliates.id AS affiliate_id" }
    let(:affiliated_products) do affiliate_user.directly_affiliated_products(alive:)
                                              .select(select_columns)
                                              .map { |product| product.slice(:name, :affiliate_id) } end
    before(:each) do
      [purchase_one, purchase_two, purchase_three, purchase_four, purchase_five, purchase_six, purchase_seven].each do |purchase|
        purchase.process!
        purchase.update_balance_and_mark_successful!
      end

      purchase_two.refund_and_save!(nil)

      purchase_six.update!(chargeback_date: Date.today)
    end

    context "when alive flag is set to true" do
      let(:alive) { true }

      it "returns only alive affiliated products" do
        expect(affiliated_products).to match_array(
          [
            { "name" => "Product 1", "affiliate_id" => direct_affiliate_one.id },
            { "name" => "Product 2", "affiliate_id" => direct_affiliate_one.id },
            { "name" => "Product 5", "affiliate_id" => direct_affiliate_three.id },
            { "name" => "Product 6", "affiliate_id" => direct_affiliate_three.id },
            { "name" => "Product 7", "affiliate_id" => direct_affiliate_three.id }
          ]
        )
      end
    end

    context "when alive flag is set to false" do
      let(:alive) { false }

      it "returns both alive and non-alive affiliated products" do
        expect(affiliated_products).to match_array(
          [
            { "name" => "Product 1", "affiliate_id" => direct_affiliate_one.id },
            { "name" => "Product 2", "affiliate_id" => direct_affiliate_one.id },
            { "name" => "Product 3", "affiliate_id" => direct_affiliate_one.id },
            { "name" => "Product 4", "affiliate_id" => direct_affiliate_two.id },
            { "name" => "Product 5", "affiliate_id" => direct_affiliate_three.id },
            { "name" => "Product 6", "affiliate_id" => direct_affiliate_three.id },
            { "name" => "Product 7", "affiliate_id" => direct_affiliate_three.id  }
          ]
        )
      end
    end
  end
end
