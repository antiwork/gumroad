# frozen_string_literal: true

require "spec_helper"

describe "First Product Starter", type: :system, js: true do
  let(:seller) { create(:user, email: "starter@example.com") }

  before do
    Feature.activate_user(:first_product_starter, seller)
    login_as(seller)
  end

  after { Feature.deactivate_user(:first_product_starter, seller) }

  it "lets a fresh seller pick a generated option and lands them in the editor", force_vcr_on: true do
    VCR.use_cassette("system/first_product_starter_spec/happy_path") do
      visit dashboard_path

      expect(page).to have_text("What do you want to sell? We'll draft it for you.")
      fill_in("Tell us what you know, make, teach, or want to sell",
              with: "I'm a Figma designer. I do SaaS onboarding audits.")
      click_button("Show me three options")

      expect(page).to have_text("Start with a template", wait: 30)
      expect(page).to have_button("Show me three more")
      within("[data-testid='product-options']") do
        buttons = all("button", text: "Make it yours →")
        expect(buttons.length).to eq(3)
        buttons.first.click
      end

      expect(page).to have_current_path(%r{/products/[^/]+/edit}, wait: 30)
      created = seller.links.order(:id).last
      expect(created).not_to be_nil
      expect(created.draft).to be(true)
    end
  end

  it "renders the Greeter alongside the starter card when the flag is on" do
    visit dashboard_path
    expect(page).to have_text("What do you want to sell? We'll draft it for you.")
    expect(page).to have_text("We're here to help you get paid for your work")
  end

  it "shows only the Greeter when the flag is off" do
    Feature.deactivate_user(:first_product_starter, seller)
    visit dashboard_path
    expect(page).to have_text("We're here to help you get paid for your work")
    expect(page).not_to have_text("What do you want to sell? We'll draft it for you.")
  end

  it "shows three template options instantly when the seller submits empty input" do
    visit dashboard_path
    click_button("Show me three options")

    expect(page).to have_text("Start with a template", wait: 10)
    within("[data-testid='product-options']") do
      expect(all("button", text: "Make it yours →").length).to eq(3)
    end
  end

  it "disables the submit button when the seller types only one word" do
    visit dashboard_path
    fill_in("Tell us what you know, make, teach, or want to sell", with: "hi")
    expect(page).to have_text("Add a few more words, or leave it empty to see starter templates.")
    expect(page).to have_button("Show me three options", disabled: true)
  end

  it "shows the capped banner inline (cards still visible, reroll relabelled) when over the AI cap" do
    stub_const("FirstProductStarterController::THROTTLE_LIMIT_PER_HOUR", 0)
    visit dashboard_path
    fill_in("Tell us what you know, make, teach, or want to sell",
            with: "I'm a Figma designer. I do SaaS onboarding audits.")
    click_button("Show me three options")

    expect(page).to have_text("Start with a template", wait: 10)
    expect(page).to have_text("You've used your AI suggestions for this hour")
    within("[data-testid='product-options']") do
      expect(all("button", text: "Make it yours →").length).to eq(3)
    end
    expect(page).to have_button("Show me three more templates")
  end
end
