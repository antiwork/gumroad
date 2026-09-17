# frozen_string_literal: true

# Throwaway QA capture — NOT to be committed. Drives the real Share tab in Chrome and
# writes screenshots to /tmp/qa/shots.
require "spec_helper"

RSpec.describe "QA capture: cart recovery card", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller, name: "Gumstein Letters") }

  before do
    create(:payment_completed, user: seller)
    create(:marketing_holdout_assignment, user: seller, marketing_holdout: false)
    Feature.activate_user(:auto_marketing, seller)
    login_as(seller, scope: :user)
    FileUtils.mkdir_p("/tmp/qa/shots")
  end

  def scroll_into_view(element)
    page.execute_script("arguments[0].scrollIntoView({block: 'center'})", element)
    sleep 1.5
  end

  it "captures the cart recovery toggle before and after, and the workflow it creates" do
    visit "#{edit_link_path(product.unique_permalink)}/share"

    expect(page).to have_text("Cart recovery", wait: 120)
    expect(page).to have_text("Off", wait: 60)

    scroll_into_view(page.find("label", text: "Recover abandoned carts"))
    expect(page).to have_text("Off", wait: 5)
    page.save_screenshot("/tmp/qa/shots/gp2720-toggle-before.png")

    find("input[role='switch']").click

    expect(page).to have_text("On", wait: 60)
    expect(page).to have_text("Open in Workflows", wait: 60)
    scroll_into_view(page.find("label", text: "Recover abandoned carts"))
    page.save_screenshot("/tmp/qa/shots/gp2720-toggle-after.png")

    click_link "Open in Workflows"

    expect(page).to have_text("You left something in your cart", wait: 120)
    sleep 2
    page.save_screenshot("/tmp/qa/shots/gp2720-workflow.png")
    puts "CAPTURE workflows=#{seller.workflows.abandoned_cart_type.alive.count} " \
         "published=#{seller.workflows.abandoned_cart_type.alive.published.count}"
  end
end
