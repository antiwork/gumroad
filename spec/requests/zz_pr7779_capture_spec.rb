# frozen_string_literal: true

# THROWAWAY capture for PR #7779 — not committed.
require "spec_helper"

describe("PR 7779 capture", type: :system, js: true) do
  let(:user) { create(:named_user, payment_address: "") }
  let(:tag) { ENV.fetch("SHOT_TAG", "after") }

  before do
    create(:user_compliance_info, user:, country: "India")
    create(:merchant_account, user:)
    create(:indian_bank_account, user:)
    login_as user
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [{ name: "prefers-color-scheme", value: "light" }])
  end

  it "captures" do
    visit settings_payments_path
    expect(page).to have_content("Bank Account", wait: 20)
    puts "LOSES_RAIL=#{user.reload.paypal_switch_loses_bank_rail?}"
    find("button[role=radio]", text: "PayPal").click
    fill_in "PayPal Email", with: "paypal@example.com"
    FileUtils.mkdir_p("/tmp/shots")
    click_on "Update settings"
    if page.has_content?("Confirm payout method change", wait: 5)
      sleep 0.5
      page.save_screenshot("/tmp/shots/#{tag}-modal.png")
      confirm = find_button("Confirm")
      puts "CONFIRM_DISABLED_BEFORE=#{confirm.disabled?}"
      fill_in 'Type "I understand" to confirm', with: "I understand"
      puts "CONFIRM_DISABLED_AFTER=#{find_button("Confirm").disabled?}"
      page.save_screenshot("/tmp/shots/#{tag}-modal-typed.png")
      click_on "Confirm"
    end
    sleep 3
    page.save_screenshot("/tmp/shots/#{tag}-result.png")
    user.reload
    puts "RESULT payment_address=#{user.payment_address.inspect} active_bank=#{user.active_bank_account.present?} stripe_account=#{user.stripe_account.present?}"
    puts "PAGE_TEXT=#{page.text[0, 400].inspect}"
  end
end
