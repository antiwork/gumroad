# frozen_string_literal: true

require "spec_helper"

describe "Wishlist card controls", :js, type: :system do
  include Rails.application.routes.url_helpers

  let(:seller) { create(:named_user) }
  let(:buyer) { create(:user) }
  let(:wishlist) { create(:wishlist, user: seller, name: "Keyboard wishlist") }

  before do
    create(:seller_profile_wishlists_section, seller:, shown_wishlists: [wishlist.id])
    login_as(buyer)
    visit root_url(host: seller.subdomain_with_protocol)
  end

  it "reaches Follow with Tab and follows/unfollows with Enter and Space" do
    title = find_link(wishlist.name)
    page.execute_script("arguments[0].focus()", title)
    title.send_keys(:tab)
    expect(page.evaluate_script("document.activeElement.getAttribute('aria-label')")).to eq("Follow")

    page.driver.browser.switch_to.active_element.send_keys(:enter)
    expect(page).to have_alert(text: "You are now following Keyboard wishlist!")
    follower = WishlistFollower.alive.find_by!(wishlist:, follower_user: buyer)

    find_button("Unfollow").send_keys(:space)
    expect(page).to have_alert(text: "You are no longer following Keyboard wishlist.")
    expect(follower.reload).to be_deleted
  end

  it "ignores repeated clicks while the follow request is pending" do
    page.execute_script(<<~JS)
      window.__followCalls = 0;
      const fetch = window.fetch;
      window.fetch = (input, options) => {
        if (String(input).includes('/wishlists/') && String(input).includes('/followers')) {
          window.__followCalls++;
          return new Promise(() => {});
        }
        return fetch(input, options);
      };
    JS

    follow = find("[aria-label='Follow']")
    follow.click
    wait_until_true { page.evaluate_script("window.__followCalls") == 1 }
    page.execute_script("arguments[0].click()", follow)
    expect(page.evaluate_script("window.__followCalls")).to eq(1)
    expect(page).to have_button("Follow", disabled: true)
  end
end
