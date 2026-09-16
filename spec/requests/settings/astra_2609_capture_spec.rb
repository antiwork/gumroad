# frozen_string_literal: true
require "spec_helper"
require "shared_examples/authorize_called"

describe "Astra 2609 capture", type: :system, js: true, mobile_view: ENV["SHOT_DEVICE"] == "mobile" do
  include_context "with Stripe API stubs"
  it "captures business type" do
    Capybara.server_port = 32609
    Capybara.app_host = "http://test.gumroad.com:32609"
    user = create(:named_user, name: "Example Seller", email: "evidence@example.com", payment_address: nil)
    info = user.fetch_or_build_user_compliance_info
    info.assign_attributes(country: "United States", is_business: true, business_country: "United States", business_type: "llc", business_name: "Example LLC")
    info.save!
    login_as user
    begin
      visit settings_payments_path
    rescue StandardError
      puts "BROWSER2609 #{page.driver.browser.logs.get(:browser).map(&:message).inspect}"
      raise
    end
    expect(page).to have_select("Type")
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [{ name: "prefers-color-scheme", value: ENV.fetch("SHOT_THEME", "light") }])
    field = find_field("Type")
    field.execute_script("this.scrollIntoView({block:'center'})")
    puts "CAPTURE2609 #{page.evaluate_script('window.innerWidth')} options=#{field.all('option').map(&:text).inspect}"
    page.save_screenshot(File.join(ENV.fetch("SHOT_DIR"), "#{ENV.fetch('SHOT_STAGE')}-#{ENV.fetch('SHOT_DEVICE')}-#{ENV.fetch('SHOT_THEME')}.png"))
    if ENV["SHOT_STAGE"] == "after"
      expect(field.value).to eq("")
      click_on "Update settings"
      expect(field["aria-invalid"]).to eq("true")
      select "LLC (multi-member)", from: "Type"
      field.execute_script("this.scrollIntoView({block:'center'})")
      page.save_screenshot(File.join(ENV.fetch("SHOT_DIR"), "after-selected-#{ENV.fetch('SHOT_DEVICE')}-#{ENV.fetch('SHOT_THEME')}.png"))
    end
  end
end
