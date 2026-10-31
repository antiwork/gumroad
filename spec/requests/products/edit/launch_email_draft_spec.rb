# frozen_string_literal: true

require "spec_helper"

describe "Launch card email draft", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller, name: "Snooze Bar") }

  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)
    create(:marketing_holdout_assignment, user: seller, marketing_holdout: false)
    Feature.activate_user(:auto_marketing, seller)
    login_as(seller)
  end

  it "saves unsaved product edits before it opens the launch email" do
    visit edit_link_path(product.unique_permalink)
    fill_in "Name", with: "Snooze Bar 2", fill_options: { clear: :backspace }
    select_tab "Share"
    click_on "Review the draft"

    draft = seller.installments.alive.sole
    expect(page).to have_current_path(edit_email_path(draft.external_id))
    expect(product.reload.name).to eq("Snooze Bar 2")
  end
end
