# frozen_string_literal: true

require "spec_helper"

describe "Optional social connections during account review", type: :system, js: true do
  let(:seller) { create(:named_seller, user_risk_state: "on_probation", twitter_handle: "example_creator") }

  before do
    create(:user_compliance_info, user: seller, country: "United States")
    Feature.deactivate(:youtube_connect)
    Feature.deactivate(:instagram_connect)
    login_as seller
  end

  it "offers a link to Social connections and leaves normal review available" do
    visit settings_payments_path

    expect(page).to have_text("Add social connections (optional)")
    expect(page).to have_link("Manage social connections", href: settings_social_connections_path)
    expect(page).to have_text("X available to connect")
    expect(page).not_to have_button("Connect to X")
    expect(page).not_to have_button("Connect to YouTube")
    expect(page).not_to have_button("Connect to Instagram")
    expect(page).to have_text("does not replace identity verification or guarantee approval or a payout date")
    within_section "Account status", section_element: :section do
      expect(page).to have_link("contact support", href: help_center_root_path)
    end
    expect(seller.reload.user_risk_state).to eq("on_probation")
    expect(seller.twitter_user_id).to be_nil
  end

  it "reflects current connections and removes the prompt when review ends" do
    seller.update!(twitter_user_id: "123")
    visit settings_payments_path
    expect(page).to have_text("X connected")
    expect(page).not_to have_button("Connect to X")

    seller.update!(twitter_user_id: nil)
    visit settings_payments_path
    expect(page).to have_text("X available to connect")

    seller.mark_compliant!(author_name: "test")
    visit settings_payments_path
    expect(page).not_to have_text("Add social connections (optional)")
  end
end
