# frozen_string_literal: true

require "spec_helper"

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

  it "refuses an old editor's toggle-off when a plan exists, rather than reporting a silent success" do
    allow(Rails.logger).to receive(:info).and_call_original

    post :update, params: editor_save_params(installment_plan: nil), as: :json

    expect(response).to have_http_status(:conflict)
    expect(Rails.logger).to have_received(:info).with(
      a_string_including("[product_editor_save_conflict]", "error_code=unmarked_installment_plan_clear_conflict", "product_id=#{product.id}")
    )
    expect(response.parsed_body).to include(
      "error_code" => "unmarked_installment_plan_clear_conflict",
      "error_message" => "This page is out of date. None of your changes were saved. Please refresh the page and try again.",
    )
    expect(product.reload.installment_plan&.number_of_installments).to eq(2)
  end

  it "refuses a stale null snapshot without clearing a newer plan or saving other changes" do
    post :update, params: editor_save_params(name: "Stale name", installment_plan: nil), as: :json

    expect(response).to have_http_status(:conflict)
    expect(product.reload.installment_plan&.number_of_installments).to eq(2)
    expect(product.reload.name).not_to eq("Stale name")
  end

  it "accepts an unmarked null when no plan exists" do
    product.installment_plan.destroy!

    post :update, params: editor_save_params(installment_plan: nil), as: :json

    expect(response).to be_successful
    expect(product.reload.installment_plan).to be_nil
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
