# frozen_string_literal: true

require "spec_helper"

describe "Old Gumroad newsletter opt-outs after the Feature announcements migration", type: :request do
  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }
  let!(:newsletter) { create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) } }
  let!(:reader) { create(:user, email: "reader@example.com") }
  let!(:follower) do
    create(:follower, user: newsletter, email: reader.email, follower_user_id: reader.id, source: Follower::From::EMBED_FORM,
                      confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
  end
  let(:other_seller) { create(:user) }
  # Followed with the address only; the migration maps it to the one confirmed account there.
  let!(:mapped_reader) { create(:user, email: "mapped-reader@example.com") }
  let!(:mapped_follow) do
    create(:follower, user: newsletter, email: mapped_reader.email, source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
  end

  before do
    host! DOMAIN
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 2)
  end

  def preference = FeatureAnnouncementSubscription.where(user_id: reader.id).pluck(:subscribed, :source)
  def mapped_preference = FeatureAnnouncementSubscription.where(user_id: mapped_reader.id).pluck(:subscribed, :source)

  describe "for a recipient the migration mapped by address" do
    it "opts out through the old cancel link" do
      expect(mapped_preference).to eq([[true, "newsletter_migration"]])

      get cancel_follow_path(mapped_follow.external_id)

      expect(mapped_follow.reload.deleted_at).to be_present
      expect(mapped_preference).to eq([[false, "newsletter_opt_out"]])
    end

    it "opts out through a spam report" do
      post = create(:audience_post, :published, seller: newsletter)

      HandleSendgridEventJob.new.perform("_json" => [{ "event" => "spamreport", "type" => "spamreport", "email" => mapped_reader.email,
                                                       "identifier" => "[999999999, #{post.id}]", "installment_id" => post.id }])

      expect(mapped_preference).to eq([[false, "newsletter_opt_out"]])
    end

    it "opts out through the buyer unsubscribe link" do
      purchase = create(:purchase, link: create(:product, user: newsletter), email: mapped_reader.email)

      get unsubscribe_purchase_path(purchase.secure_external_id(scope: "unsubscribe"))

      expect(mapped_follow.reload.deleted_at).to be_present
      expect(mapped_preference).to eq([[false, "newsletter_opt_out"]])
    end
  end

  it "writes the opt-out in the same transaction as the follower change, so a rollback keeps consent" do
    ApplicationRecord.transaction do
      Follower.find(follower.id).mark_deleted!
      expect(preference).to eq([[false, "newsletter_opt_out"]])
      raise ActiveRecord::Rollback
    end

    expect(preference).to eq([[true, "newsletter_migration"]])
    expect(follower.reload.deleted_at).to be_nil
  end

  it "fails the old unsubscribe rather than losing the opt-out when the new row can't be written" do
    allow(FeatureAnnouncementSubscription).to receive(:unsubscribe!).and_raise(ActiveRecord::LockWaitTimeout)

    expect { get cancel_follow_path(follower.external_id) }.to raise_error(ActiveRecord::LockWaitTimeout)

    expect(follower.reload.deleted_at).to be_nil
    expect(preference).to eq([[true, "newsletter_migration"]])
  end

  it "opts out through the old newsletter's cancel link and drops the follower from the audience" do
    get cancel_follow_path(follower.external_id)

    expect(response).to have_http_status(:ok)
    expect(follower.reload.deleted_at).to be_present
    expect(preference).to eq([[false, "newsletter_opt_out"]])
    expect(AudienceMember.find_by(seller: newsletter, email: reader.email)&.details&.dig("follower")).to be_nil
  end

  it "opts out through a spam report on a newsletter post" do
    post = create(:audience_post, :published, seller: newsletter)

    HandleSendgridEventJob.new.perform("_json" => [{ "event" => "spamreport", "type" => "spamreport", "email" => reader.email,
                                                     "identifier" => "[999999999, #{post.id}]", "installment_id" => post.id }])

    expect(follower.reload.deleted_at).to be_present
    expect(preference).to eq([[false, "newsletter_opt_out"]])
  end

  it "opts out through the buyer unsubscribe link and keeps the purchase uncontactable" do
    purchase = create(:purchase, link: create(:product, user: newsletter), email: reader.email)

    get unsubscribe_purchase_path(purchase.secure_external_id(scope: "unsubscribe"))

    expect(purchase.reload.can_contact).to be(false)
    expect(follower.reload.deleted_at).to be_present
    expect(preference).to eq([[false, "newsletter_opt_out"]])
  end

  it "leaves the preference alone when the reader leaves another creator's list" do
    other_follow = create(:active_follower, user: other_seller, email: reader.email, follower_user_id: reader.id)
    other_purchase = create(:purchase, link: create(:product, user: other_seller), email: reader.email)

    get cancel_follow_path(other_follow.external_id)
    get unsubscribe_purchase_path(other_purchase.secure_external_id(scope: "unsubscribe"))

    expect(other_purchase.reload.can_contact).to be(false)
    expect(preference).to eq([[true, "newsletter_migration"]])
  end
end
