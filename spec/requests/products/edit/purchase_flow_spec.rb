# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("ProductPurchaseFlowScenario", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }

  include_context "with switching account to user as admin for seller"

  it "always shows the Require shipping information toggle for all product types" do
    product.update!(require_shipping: true)
    visit edit_link_path(product.unique_permalink)

    expect(page).to have_field("Require shipping information")
    uncheck("Require shipping information")

    save_change
    visit current_path
    expect(page).to have_field("Require shipping information")

    expect(product.reload.require_shipping).to be false
  end
end
