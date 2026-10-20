# frozen_string_literal: true

require "spec_helper"

# Leaving the old Gumroad newsletter after the copy opts the account out of Feature announcements. A follow
# request nobody confirmed was never part of the newsletter, so cancelling or removing it leaves the account's
# own Feature announcements choice alone.
describe FollowersController, "cancelling old Gumroad newsletter follows after the copy" do
  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }
  let!(:newsletter) { create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) } }
  let!(:chose_in) { create(:user, email: "pending-chose-in@example.com") }
  let!(:chose_out) { create(:user, email: "pending-chose-out@example.com") }
  let!(:member) { create(:user, email: "confirmed-member@example.com") }
  # Requested, linked to the account or at its address, never confirmed.
  let!(:pending_in) { create(:follower, user: newsletter, email: chose_in.email, follower_user_id: chose_in.id, confirmed_at: nil) }
  let!(:pending_out) { create(:follower, user: newsletter, email: chose_out.email, confirmed_at: nil) }
  let!(:member_follow) do
    create(:follower, user: newsletter, email: member.email, follower_user_id: member.id, source: Follower::From::EMBED_FORM,
                      confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
  end

  before do
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    FeatureAnnouncementSubscription.create!(user_id: chose_in.id, subscribed: true, source: "settings")
    FeatureAnnouncementSubscription.unsubscribe!(chose_out, source: "unsubscribe_link")
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 1)
  end

  def choice(user) = FeatureAnnouncementSubscription.find_by!(user_id: user.id).attributes.slice("subscribed", "source", "version", "created_at", "updated_at")

  it "keeps both accounts' choices exactly as they were when their unconfirmed requests are cancelled" do
    before_choices = [choice(chose_in), choice(chose_out)]

    get :cancel, params: { id: pending_in.external_id }
    get :cancel, params: { id: pending_out.external_id }

    expect([pending_in.reload.deleted?, pending_out.reload.deleted?]).to eq([true, true])
    expect([choice(chose_in), choice(chose_out)]).to eq(before_choices)
  end

  it "keeps both accounts' choices exactly as they were when the seller removes their unconfirmed requests" do
    before_choices = [choice(chose_in), choice(chose_out)]
    sign_in newsletter

    delete :destroy, params: { id: pending_in.external_id }
    delete :destroy, params: { id: pending_out.external_id }

    expect([pending_in.reload.deleted?, pending_out.reload.deleted?]).to eq([true, true])
    expect([choice(chose_in), choice(chose_out)]).to eq(before_choices)
  end

  it "still opts out a member who was confirmed, through the old cancel link after the account's email changed" do
    member.update_columns(email: "confirmed-member-moved@example.com")
    expect(choice(member).values_at("subscribed", "source")).to eq([true, "newsletter_migration"])

    get :cancel, params: { id: member_follow.external_id }

    expect(member_follow.reload.attributes.values_at("deleted_at", "confirmed_at").map(&:present?)).to eq([true, false])
    expect(choice(member).values_at("subscribed", "source")).to eq([false, "newsletter_opt_out"])
  end

  it "still opts out a member who was confirmed when the seller removes them" do
    sign_in newsletter

    delete :destroy, params: { id: member_follow.external_id }

    expect(choice(member).values_at("subscribed", "source")).to eq([false, "newsletter_opt_out"])
  end
end
