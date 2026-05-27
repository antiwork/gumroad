# frozen_string_literal: true

require "spec_helper"

# Runs through the full middleware stack (unlike the controller spec) so it
# catches SecureHeaders overwriting the response CSP. The landing_iframe_content
# action opts out of SecureHeaders' CSP and sets its own strict one; if that
# opt-out regressed, the seller's inline scripts would be silently CSP-blocked.
describe "GET /l/:id/landing/embed CSP", type: :request do
  let(:seller) { create(:user, username: "landingseller") }
  let(:product) { create(:product, user: seller, custom_html: "<section><script>window.ok = true;</script></section>") }

  it "serves the strict custom_html CSP, not the app default from SecureHeaders" do
    get "/l/#{product.unique_permalink}/landing/embed", headers: { "HOST" => VALID_REQUEST_HOSTS.first }

    expect(response).to be_successful
    csp = response.headers["Content-Security-Policy"]
    # Strict, seller-scoped CSP — allows the seller's inline scripts.
    expect(csp).to include("default-src 'none'")
    expect(csp).to include("script-src 'unsafe-inline'")
    expect(csp).to include("connect-src 'none'")
    expect(csp).to include("img-src data: blob: https:")
    expect(csp).not_to include("img-src *")
    # media-src present so the allowed <audio>/<video> tags aren't blocked by default-src 'none'.
    expect(csp).to include("media-src data: blob: https:")
    # Not the SecureHeaders default (which would block inline scripts).
    expect(csp).not_to include("default-src 'self'")
  end

  it "sandboxes the response itself so a direct top-level load can't run scripts same-origin" do
    get "/l/#{product.unique_permalink}/landing/embed", headers: { "HOST" => VALID_REQUEST_HOSTS.first }

    csp = response.headers["Content-Security-Policy"]
    # CSP sandbox applies whether the doc is framed or loaded directly — the
    # iframe attribute alone wouldn't cover a direct navigation to this URL.
    expect(csp).to include("sandbox allow-scripts allow-forms")
    expect(csp).not_to include("allow-same-origin")
    expect(csp).not_to include("allow-top-navigation")
  end
end
