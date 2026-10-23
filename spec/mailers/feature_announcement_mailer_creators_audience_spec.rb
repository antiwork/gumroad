# frozen_string_literal: true

require "spec_helper"

describe FeatureAnnouncementMailer, "creators audience" do
  before do
    create(:feature_announcement_campaign, key: "creators_campaign", audience: "creators")
    ActionMailer::Base.deliveries.clear
  end

  def deliver_to(user)
    FeatureAnnouncementSubscription.update_from_settings!(user, subscribed: true, rendered_version: 0)
    described_class.announcement(campaign: "creators_campaign", user_id: user.id, email: user.email).deliver_now
    FeatureAnnouncementDelivery.find_by!(campaign: "creators_campaign", user_id: user.id)
  end

  it "delivers to an account that has made a product" do
    seller = create(:product, user: create(:user, email: "creator@example.com")).user

    expect(deliver_to(seller).state).to eq("delivered")
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["creator@example.com"]])
  end

  it "keeps a creator whose products are all deleted, as User#is_buyer? does" do
    seller = create(:product).user
    seller.products.each(&:mark_deleted!)

    expect(deliver_to(seller).state).to eq("delivered")
  end

  {
    "a buyer" => -> { create(:user).tap { create(:purchase, purchaser: _1, email: _1.email) } },
    "a follower" => -> { create(:user).tap { create(:active_follower, email: _1.email, follower_user_id: _1.id) } },
    "a signup with no products" => -> { create(:user) },
  }.each do |name, build|
    it "skips #{name}" do
      expect(deliver_to(instance_exec(&build)).attributes.slice("state", "reason")).to eq("state" => "skipped", "reason" => "not_in_audience")
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end
