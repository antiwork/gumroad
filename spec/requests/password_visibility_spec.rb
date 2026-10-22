# frozen_string_literal: true

require "spec_helper"

describe "Password visibility", type: :system, js: true do
  [:enter, " "].each do |key|
    it "reaches the login toggle with Tab and activates it with #{key.inspect} without submitting" do
      visit login_path
      fill_in "Email", with: "viewer@example.com"
      fill_in "Password", with: "Example password"
      page.execute_script("window.visibilitySubmitCount = 0; document.addEventListener('submit', event => { event.preventDefault(); event.stopImmediatePropagation(); window.visibilitySubmitCount++; }, true)")

      find_field("Password").send_keys(:tab)
      expect(page.evaluate_script("document.activeElement.getAttribute('aria-label')")).to eq("Show password")
      page.driver.browser.switch_to.active_element.send_keys(key)
      expect(find_field("Password")[:type]).to eq("text")
      expect(find_field("Password").value).to eq("Example password")
      page.driver.browser.switch_to.active_element.send_keys(key)
      expect(find_field("Password")[:type]).to eq("password")
      expect(page.evaluate_script("window.visibilitySubmitCount")).to eq(0)
      expect(page).to have_current_path(login_path)
    end
  end
end
