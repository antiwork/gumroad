# frozen_string_literal: true

require "spec_helper"

describe "Admin::PurchasesController Scenario", type: :system, js: true do
  let(:admin) { create(:admin_user) }
  let(:purchase) { create(:purchase, purchaser: create(:user), is_deleted_by_buyer: true) }

  before do
    login_as(admin)
  end

  describe "undelete functionality" do
    it "shows undelete button for deleted purchases" do
      visit admin_purchase_path(purchase.id)

      expect(page).to have_button("Undelete")
    end

    it "does not show undelete button for non-deleted purchases" do
      purchase.update!(is_deleted_by_buyer: false)
      visit admin_purchase_path(purchase.id)

      expect(page).not_to have_button("Undelete")
    end

    it "successfully undeletes a purchase" do
      visit admin_purchase_path(purchase.id)

      expect(purchase.reload.is_deleted_by_buyer).to be(true)

      click_button "Undelete"
      accept_browser_dialog
      wait_for_ajax

      expect(purchase.reload.is_deleted_by_buyer).to be(false)
      expect(page).not_to have_button("Undelete")
    end

    it "creates audit trail comments when undeleting" do
      visit admin_purchase_path(purchase.id)

      expect do
        click_button "Undelete"
        accept_browser_dialog
        wait_for_ajax
      end.to change { purchase.comments.where(comment_type: "note").count }.by(1)
       .and change { purchase.purchaser.comments.where(comment_type: "note").count }.by(1)
    end
  end

  private

  def accept_browser_dialog
    wait = Selenium::WebDriver::Wait.new(timeout: 30)
    wait.until do
      page.driver.browser.switch_to.alert
      true
    rescue Selenium::WebDriver::Error::NoAlertPresentError
      false
    end
    page.driver.browser.switch_to.alert.accept
  end

  def wait_for_ajax
    Timeout.timeout(Capybara.default_max_wait_time) do
      loop until finished_all_ajax_requests?
    end
  end

  def finished_all_ajax_requests?
    page.evaluate_script('jQuery.active').zero?
  end
end
