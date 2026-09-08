# frozen_string_literal: true

require "spec_helper"

describe SettingsPresenter, "optional social connections for account review" do
  let(:seller) { create(:named_seller) }
  let(:user) { seller }
  let(:presenter) { described_class.new(pundit_user: SellerContext.new(user:, seller:)) }

  def connections
    presenter.payments_props[:account_status][:social_connections_for_review]
  end

  before do
    create(:user_compliance_info, user: seller, country: "United States")
    Feature.deactivate(:youtube_connect)
    Feature.deactivate(:instagram_connect)
  end

  %w[on_probation flagged_for_fraud flagged_for_tos_violation].each do |state|
    it "offers optional X connection for an owner in #{state}" do
      seller.update!(user_risk_state: state)
      expect(connections).to eq([{ provider: "twitter", connected: false }])
    end
  end

  %w[not_reviewed compliant suspended_for_fraud suspended_for_tos_violation].each do |state|
    it "does not offer social connections for #{state}, even with an internal payout pause" do
      seller.update!(user_risk_state: state, payouts_paused_internally: true)
      expect(connections).to be_nil
    end
  end

  it "does not mistake unrelated Stripe, system, admin or seller pauses for a risk review" do
    seller.update!(user_risk_state: "compliant")
    %w[stripe system admin user].each do |source|
      seller.update!(payouts_paused_internally: source != "user", payouts_paused_by_user: source == "user", payouts_paused_by: source)
      expect(connections).to be_nil
    end
  end

  context "with a team admin" do
    let(:user) { create(:user) }

    it "keeps payment settings accessible without offering owner-only connections" do
      create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)
      seller.update!(user_risk_state: "on_probation")
      expect(Pundit.policy!(SellerContext.new(user:, seller:), [:settings, :payments, seller]).show?).to be true
      expect(connections).to be_nil
    end
  end

  it "uses the current X identity, not a manually entered handle or historical verification" do
    seller.update!(user_risk_state: "on_probation", twitter_handle: "example_creator")
    create(:social_connect_verification, user: seller, platform: "twitter", uid: "123")
    expect(connections).to eq([{ provider: "twitter", connected: false }])
    seller.update!(twitter_user_id: "123")
    expect(connections).to eq([{ provider: "twitter", connected: true }])
    seller.update!(twitter_user_id: nil)
    expect(connections).to eq([{ provider: "twitter", connected: false }])
  end

  it "offers only seller-enabled providers and reads current identity associations" do
    seller.update!(user_risk_state: "on_probation")
    Feature.activate_user(:youtube_connect, seller)
    Feature.activate_user(:instagram_connect, seller)
    expect(connections).to eq([
                                { provider: "twitter", connected: false },
                                { provider: "youtube", connected: false },
                                { provider: "instagram", connected: false },
                              ])
    seller.create_youtube_identity!(channel_id: "example_channel", handle: "example_creator")
    seller.create_instagram_identity!(instagram_user_id: "123", handle: "example_creator")
    expect(connections.last(2)).to eq([
                                        { provider: "youtube", connected: true },
                                        { provider: "instagram", connected: true },
                                      ])
    seller.youtube_identity.destroy!
    seller.instagram_identity.destroy!
    seller.reload
    expect(connections.last(2).map { _1[:connected] }).to eq([false, false])
  end

  it "does not borrow provider availability from another seller" do
    seller.update!(user_risk_state: "on_probation")
    other = create(:user)
    Feature.activate_user(:youtube_connect, other)
    Feature.activate_user(:instagram_connect, other)
    expect(connections).to eq([{ provider: "twitter", connected: false }])
  end
end
