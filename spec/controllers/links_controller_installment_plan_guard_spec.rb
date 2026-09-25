# frozen_string_literal: true

require "spec_helper"

# Regression coverage for gumroad-private#2958. `installment_plan` was the one
# scalar in the product-editor save payload with no "unspecified" guard, and
# LinksController#update_installment_plan read an absent or null plan as an
# explicit "remove the plan" — hard-deleting it (ProductInstallmentPlan uses
# Deletable, and a plan with no payment options is destroyed with no audit
# trail). Any save from a snapshot taken before the seller's plan existed (a
# second tab, a stale editor) therefore wiped it silently.
describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller, price_cents: 10_000) }

  before do
    product.create_installment_plan!(number_of_installments: 2)
    sign_in seller
  end

  def editor_save_params(overrides = {})
    {
      id: product.unique_permalink,
      name: product.name,
      description: "A description",
      price_currency_type: "usd",
      price_cents: product.price_cents,
      customizable_price: false,
      covers: [],
      files: [],
      has_same_rich_content_for_all_variants: false,
      rich_content: [],
      variants: [],
      confirmed_removed_variant_ids: [],
      confirmed_removed_rich_content_ids: [],
      preserved_rich_content_ids: [],
      rich_content_provenance_version: 1,
    }.merge(overrides)
  end

  it "keeps the seller's plan when the payload does not carry installment_plan at all" do
    post :update, params: editor_save_params, as: :json

    expect(response).to be_successful
    expect(product.reload.installment_plan&.number_of_installments).to eq(2)
  end

  it "ignores a null installment_plan from a session that did not mark it a clear" do
    post :update, params: editor_save_params(installment_plan: nil), as: :json

    expect(response).to be_successful
    expect(product.reload.installment_plan&.number_of_installments).to eq(2)
  end

  it "clears the plan when the session marks the toggle-off as a deliberate clear" do
    post :update, params: editor_save_params(installment_plan: nil, installment_plan_changed: true), as: :json

    expect(response).to be_successful
    expect(product.reload.installment_plan).to be_nil
  end

  it "stores an edited installment count" do
    post :update, params: editor_save_params(installment_plan: { number_of_installments: 4 }), as: :json

    expect(response).to be_successful
    expect(product.reload.installment_plan.number_of_installments).to eq(4)
  end
end
