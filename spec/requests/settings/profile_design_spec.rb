# frozen_string_literal: true

require "spec_helper"

describe "Profile settings design", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  before { login_as(seller) }

  def open_design_tab
    visit profile_path
    find("[role=tab]", text: "Design").click
  end

  def choice(group, name)
    find("[role=radiogroup][aria-label='#{group}'] [role=radio]", text: name, exact_text: true)
  end

  def expect_selected(group, name)
    expect(page).to have_css("[role=radiogroup][aria-label='#{group}'] [role=radio][aria-checked=true]", text: name, exact_text: true)
  end

  def save_changes
    click_on "Update profile"
    # The toast only appears after both the settings PUT and the Inertia props reload finish.
    within(find("[data-testid='toast-alert']", wait: 30)) { expect(page).to have_text("Changes saved!", wait: 30) }
  end

  it "saves a color preset, corners and button hover and shows them selected after a reload" do
    open_design_tab
    choice("Color presets", "Dark").click
    choice("Corners", "Large").click
    uncheck "Button hover effect"
    save_changes

    # `seller.seller_profile` would return the unsaved profile built before the browser created the row.
    expect(seller.reload.seller_profile).to have_attributes(
      background_color: "#000000",
      highlight_color: "#ffffff",
      border_radius: "large",
      button_hover: "none",
    )

    open_design_tab
    expect_selected("Color presets", "Dark")
    expect_selected("Corners", "Large")
    expect(page).to have_unchecked_field("Button hover effect")
  end

  it "switches from the custom landing page to the theme preview on Design and back" do
    Feature.activate_user(:custom_html_pages, seller)
    seller.update!(custom_html: "<main>Custom landing page</main>")
    visit profile_path

    within_frame(find("iframe[title='Custom profile page preview']")) do
      expect(page).to have_text("Custom landing page")
    end

    find("[role=tab]", text: "Design").click
    expect(page).to have_no_css("iframe[title='Custom profile page preview']")
    expect(page).to have_css("[role=document]")
    choice("Color presets", "Dark").click
    expect(find("[role=document] > div").style("background-color")).to eq("background-color" => "rgba(0, 0, 0, 1)")

    find("[role=tab]", text: "About").click
    expect(page).to have_no_css("[role=document]")
    within_frame(find("iframe[title='Custom profile page preview']")) do
      expect(page).to have_text("Custom landing page")
    end
  end

  it "selects the stored preset for uppercase colors and changes corners with the arrow keys" do
    seller.seller_profile.tap(&:save!).update_columns(background_color: "#FFFFFF", highlight_color: "#000000")
    open_design_tab

    expect_selected("Color presets", "Black and white")

    choice("Corners", "Small").native.send_keys(:arrow_right)
    expect_selected("Corners", "Medium")
    expect(page).to have_css("[role=radio]:focus", text: "Medium", exact_text: true)
    save_changes

    expect(seller.seller_profile.reload.border_radius).to eq("medium")
  end
end
