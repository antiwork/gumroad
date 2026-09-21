# frozen_string_literal: true

require "spec_helper"

describe "Stripe field synchronization", type: :system, js: true do
  it "re-enters input truncated during typing before continuing" do
    html = <<~HTML
      <input placeholder="MM / YY">
      <script>
        document.querySelector('input').addEventListener('input', function truncate() {
          if (this.value === '12/26') {
            this.value = '12/2';
            this.removeEventListener('input', truncate);
          }
        });
      </script>
    HTML
    visit "data:text/html,#{ERB::Util.url_encode(html)}"

    fill_in_stripe_field ["MM / YY"], with: "12/26"

    expect(page).to have_field("MM / YY", with: "12/26")
  end

  it "fails when a field never retains the complete requested value" do
    visit "data:text/html,#{ERB::Util.url_encode('<input placeholder="MM / YY" maxlength="1">')}"

    expect do
      using_wait_time(0.2) { fill_in_stripe_field ["MM / YY"], with: "12/26" }
    end.to raise_error(Capybara::ExpectationNotMet, "Stripe field MM / YY did not retain the complete requested value")
    expect(page).to have_field("MM / YY", with: "1")
  end
end
