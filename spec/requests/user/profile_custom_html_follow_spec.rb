# frozen_string_literal: true

require "spec_helper"

# The custom-HTML profile is sandboxed so it can never reach gumroad.com on
# its own: the sanitizer strips form actions and the CSP sets connect-src
# 'none'. The gumroad:follow postMessage bridge is the supported email-capture
# path — the sandboxed page asks, the trusted same-origin wrapper validates
# and POSTs to the public follow endpoint with ITS OWN seller id, then relays
# the outcome back so the page can show a confirmation. These specs drive that
# flow in a real browser.
describe "Profile custom HTML page follow bridge", type: :system, js: true do
  let(:seller) { create(:user, username: "followstudio", name: "Follow Studio") }
  let(:other_seller) { create(:user) }

  let(:custom_html) do
    <<~HTML
      <main>
        <h1>Join the list</h1>
        <form data-gumroad-follow>
          <input type="email" name="email" placeholder="Your email">
          <button type="submit">Subscribe</button>
        </form>
        <p data-gumroad-follow-message></p>
        <button id="evil-follow" type="button">Evil follow</button>
        <script>
          // Simulates malicious seller HTML trying to subscribe an address to
          // a DIFFERENT seller's audience — the trusted wrapper must ignore
          // the seller_id in the message and use its own.
          document.getElementById("evil-follow").addEventListener("click", function () {
            parent.postMessage({ type: "gumroad:follow", email: "victim@example.com", seller_id: "#{other_seller.external_id}" }, "*");
          });
        </script>
      </main>
    HTML
  end

  before do
    Feature.activate_user(:custom_html_pages, seller)
    seller.update!(custom_html:)
  end

  it "creates the follower and shows the confirmation message inside the sandboxed page" do
    visit seller.subdomain_with_protocol

    within_frame(find("iframe#gumroad-landing-frame")) do
      fill_in "Your email", with: "fan@example.com"
      click_on "Subscribe"
      # The wrapper's reply fills the message slot and flags the form, so a
      # page can show a confirmation with no scripting of its own.
      expect(page).to have_text("Check your inbox to confirm your follow request.", wait: 10)
      expect(page).to have_css('form[data-gumroad-follow-state="success"]')
    end

    follower = Follower.last
    expect(follower.user).to eq(seller)
    expect(follower.email).to eq("fan@example.com")
    expect(follower.source).to eq(Follower::From::EMBED_FORM)
  end

  it "ignores a seller_id in the message — a follow can only ever land on the wrapper's own seller" do
    visit seller.subdomain_with_protocol

    within_frame(find("iframe#gumroad-landing-frame")) do
      click_on "Evil follow"
      expect(page).to have_css("form[data-gumroad-follow-state]", wait: 10)
    end

    expect(other_seller.followers.count).to eq(0)
    follower = Follower.last
    expect(follower.user).to eq(seller)
    expect(follower.email).to eq("victim@example.com")
  end
end
