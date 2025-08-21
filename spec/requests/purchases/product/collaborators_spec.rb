# frozen_string_literal: true

require("spec_helper")

describe("Product checkout - with collaborator", type: :system, js: true) do
  let(:product) { create(:product, :recommendable, price_cents: 20_00) }
  let!(:collaborator) { create(:collaborator, affiliate_basis_points: 50_00, products: [product]) }

  it "credits the collaborator if the product has a collaborator" do
    visit short_link_path(product.unique_permalink)

    complete_purchase(product)

    purchase = Purchase.last
    expect(purchase.affiliate).to eq collaborator
    expect(purchase.affiliate_credit_cents).to eq 10_00 - (purchase.fee_cents * 0.5)
  end

  context "when an affiliate is set" do
    it "ignores the affiliate" do
      affiliate = create(:user).global_affiliate # products with collaborators can't have direct affiliates
      visit affiliate.referral_url_for_product(product)

      complete_purchase(product)

      purchase = Purchase.last
      expect(purchase.affiliate).to eq collaborator
      expect(purchase.affiliate_credit_cents).to eq 10_00 - (purchase.fee_cents * 0.5)
    end
  end
end
