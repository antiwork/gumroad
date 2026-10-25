# frozen_string_literal: true

require "spec_helper"

describe "Payout export recovery", :js, type: :system do
  let(:seller) { create(:named_seller) }
  let!(:payment) { create(:payment_completed, user: seller) }

  it "retries a failed list request without reopening or exporting a payout" do
    login_as seller
    visit balance_path
    page.execute_script <<~JS
      const originalFetch = window.fetch;
      window.payoutExportAttempts = 0;
      window.fetch = (...args) => {
        if (String(args[0]).includes('/payouts/exportables') && ++window.payoutExportAttempts === 1) {
          return Promise.resolve(new Response('{}', {status: 500, headers: {'Content-Type': 'application/json'}}));
        }
        return originalFetch(...args);
      };
    JS
    click_on "Export all"
    expect(page).to have_alert(text: "Unable to load payouts. Try again.")
    expect(page).not_to have_selector("[role='progressbar']")
    click_on "Try again"
    expect(page).to have_button("Select all", disabled: false)
    click_on "Select all"
    expect(page).to have_button("Download", disabled: false)
    expect(page.evaluate_script("window.payoutExportAttempts")).to eq(2)
    expect(payment.reload.state).to eq("completed")
  end
end
