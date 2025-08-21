# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "User Follow Page Scenario", type: :system, js: true do
  include FillInUserProfileHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:other_user) { create(:user) }
  let(:follower_email) { generate(:email) }

  it "allows user to follow when logged in" do
    login_as(other_user)
    expect do
      visit seller.subdomain_with_protocol
      submit_follow_form
      wait_for_ajax
      Follower.where(email: other_user.email).first.confirm!
      expect(page).to have_button("Subscribed", disabled: true)
    end.to change { seller.followers.active.count }.by(1)
    expect(Follower.last.follower_user_id).to eq other_user.id
  end

  context "with seller as logged_in_user" do
    before do
      login_as(seller)
    end

    it "doesn't prefill the email" do
      visit seller.subdomain_with_protocol
      expect(find("input[type='email']").value).to be_empty
    end

    context "with switching account to user as admin for seller" do
      include_context "with switching account to user as admin for seller"

      it "doesn't allow to follow logged-in user's profile" do
        visit user_with_role_for_seller.subdomain_with_protocol
        expect(find("input[type='email']").value).to be_empty
        submit_follow_form(with: user_with_role_for_seller.email)
        expect(page).to have_alert(text: "As the creator of this profile, you can't follow yourself!")
      end
    end
  end

  context "without user logged in" do
    it "allows user to follow" do
      visit seller.subdomain_with_protocol
      expect do
        submit_follow_form(with: follower_email)
        wait_for_ajax
        Follower.find_by(email: follower_email).confirm!
      end.to change { seller.followers.active.count }.by(1)
      expect(Follower.last.email).to eq follower_email
    end
  end
end
