# frozen_string_literal: true

require "spec_helper"

# Feature announcements delivery reads only its own preference, so a contact opt-out recorded for the old
# Gumroad newsletter's buyers after the copy has to reach that preference too.
describe PurchasesController, "turning contact off for a buyer after the old Gumroad newsletter was copied" do
  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }
  let!(:newsletter) { create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) } }
  # In the piracy-reports audience, so an announcement can actually be delivered to them.
  let!(:buyer) { create_piracy_seller_with_product.first.tap { _1.update_columns(email: "opting-out-buyer@example.com") } }
  let!(:newsletter_product) { create(:product, user: newsletter) }
  let!(:purchase) { create(:purchase, link: newsletter_product, email: buyer.email) }

  before do
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    create(:follower, user: newsletter, email: buyer.email, follower_user_id: buyer.id, source: Follower::From::EMBED_FORM,
                      confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 1)
    ActionMailer::Base.deliveries.clear
  end

  def preference(user = buyer) = FeatureAnnouncementSubscription.where(user_id: user.id).pluck(:subscribed, :source)

  def turn_contact(purchase, on)
    sign_out :user
    sign_in purchase.seller
    post :change_can_contact, params: { id: purchase.external_id, can_contact: on }
    expect(response).to have_http_status(:no_content)
  end

  def announce(user)
    FeatureAnnouncementMailer.announcement(campaign: "piracy_reports", user_id: user.id, email: user.email).deliver_now
    FeatureAnnouncementDelivery.find_by!(campaign: "piracy_reports", user_id: user.id)
  end

  it "opts the account out of Feature announcements, so the next announcement is refused" do
    expect(preference).to eq([[true, "newsletter_migration"]])

    turn_contact(purchase, false)

    expect(purchase.reload.can_contact).to be(false)
    expect(preference).to eq([[false, "newsletter_opt_out"]])
    expect(announce(buyer).attributes.slice("state", "reason")).to eq("state" => "skipped", "reason" => "not_subscribed")
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "lets a later Settings opt-in win over the older opt-out" do
    turn_contact(purchase, false)

    version = FeatureAnnouncementSubscription.state_for(buyer)[:version]
    expect(FeatureAnnouncementSubscription.update_from_settings!(buyer, subscribed: true, rendered_version: version)).to eq(:updated)

    expect(announce(buyer).state).to eq("delivered")
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([[buyer.email]])
    expect(purchase.reload.can_contact).to be(false)
  end

  it "never turns Feature announcements on when contact is turned back on" do
    turn_contact(purchase, false)
    turn_contact(purchase, true)

    expect(purchase.reload.can_contact).to be(true)
    expect(preference).to eq([[false, "newsletter_opt_out"]])
  end

  it "reaches an account that opted in from Settings and never followed the newsletter" do
    settings_buyer = create(:user, email: "settings-buyer@example.com")
    FeatureAnnouncementSubscription.update_from_settings!(settings_buyer, subscribed: true, rendered_version: 0)
    settings_purchase = create(:purchase, link: newsletter_product, email: settings_buyer.email)

    turn_contact(settings_purchase, false)

    expect(preference(settings_buyer)).to eq([[false, "newsletter_opt_out"]])
  end

  it "doesn't count a purchase created opted out, because of an older opt-out, as a new one" do
    returning_buyer = create(:user, email: "returning-buyer@example.com")
    create(:purchase, link: newsletter_product, email: returning_buyer.email, can_contact: false)
    FeatureAnnouncementSubscription.update_from_settings!(returning_buyer, subscribed: true, rendered_version: 0)

    inherited = create(:purchase, link: newsletter_product, email: returning_buyer.email)

    expect([inherited.reload.can_contact, inherited.can_contact_reason]).to eq([false, Purchase::CAN_CONTACT_REASON_INHERITED])
    expect(preference(returning_buyer)).to eq([[true, "settings"]])
  end

  it "leaves Feature announcements alone when another creator turns contact off for the same buyer" do
    other_purchase = create(:purchase, link: create(:product), email: buyer.email)

    turn_contact(other_purchase, false)

    expect(other_purchase.reload.can_contact).to be(false)
    expect(preference).to eq([[true, "newsletter_migration"]])
  end
end
