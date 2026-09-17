# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Cart recovery", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller) }

  before do
    create(:payment_completed, user: seller)
    create(:marketing_holdout_assignment, user: seller, marketing_holdout: false)
    Feature.activate_user(:auto_marketing, seller)
    login_as(seller, scope: :user)
  end

  it "enables and pauses a reminder without leaving Share" do
    visit "#{edit_link_path(product.unique_permalink)}/share"

    expect(page).to have_link("Continue on X")
    expect(page).not_to have_text("Coming soon")
    find("label", text: "Abandoned cart email", exact_text: true).click
    expect(page).to have_checked_field("Abandoned cart email")
    expect(page).to have_link("Edit email")
    expect(seller.workflows.alive.abandoned_cart_type.published.count).to eq(1)

    find("label", text: "Abandoned cart email", exact_text: true).click
    expect(page).to have_unchecked_field("Abandoned cart email")
    expect(seller.workflows.alive.abandoned_cart_type.published.count).to eq(0)
    expect(seller.workflows.alive.abandoned_cart_type.count).to eq(1)
  end

  it "previews edited email content without active scripts or unsafe links" do
    workflow = Marketing::AbandonedCart.new(product:, seller:).enable
    workflow.installments.alive.sole.update!(
      name: "Your workbook is waiting",
      message: '<p>Return to your workbook.</p><script>window.unsafePreview = true</script><a href="javascript:alert(1)">Unsafe link</a>'
    )

    visit "#{edit_link_path(product.unique_permalink)}/share"
    find("summary", text: "Preview email").click

    expect(page).to have_text("Your workbook is waiting")
    within_frame(find('iframe[title="Email preview"]')) do
      expect(page).to have_text("Return to your workbook.")
      expect(page).to have_css("a:not([href])", text: "Unsafe link")
      expect(page.evaluate_script("window.unsafePreview === undefined")).to eq(true)
    end
  end
end
