# frozen_string_literal: true

require("spec_helper")

describe("Product checkout - with pending collaborators", type: :system, js: true) do
  let(:product) { create(:product, :recommendable, price_cents: 20_00) }

  let!(:pending_collaborator) do
    create(
      :collaborator,
      :with_pending_invitation,
      affiliate_basis_points: 50_00,
      products: [product]
    )
  end

  it "does not credit the collaborator if the collaborator has not accepted the invitation" do
    visit short_link_path(product.unique_permalink)

    complete_purchase(product)

    purchase = Purchase.last
    expect(purchase.affiliate).to be_nil
    expect(purchase.affiliate_credit_cents).to eq 0
  end

  context "when an affiliate is set" do
    # Products with collaborators can't have direct affiliates.
    let!(:global_affiliate) { create(:user).global_affiliate }

    it "credits the affiliate" do
      visit global_affiliate.referral_url_for_product(product)

      complete_purchase(product)

      purchase = Purchase.last
      expect(purchase.affiliate).to eq global_affiliate
      expect(purchase.affiliate_credit_cents).to eq 1_66
    end
  end
end
