# frozen_string_literal: true

require "spec_helper"

describe Onetime::SendTopCreatorAnnouncementEmail do
  before do
    @verified_user_1 = create(:compliant_user, verified: true)
    @verified_user_2 = create(:compliant_user, verified: true)
    @unverified_user = create(:compliant_user, verified: false)
    @deleted_user = create(:user, :deleted, verified: true)
    @suspended_user = create(:tos_user, verified: true)
    @no_email_user = create(:compliant_user, verified: true)
    @no_email_user.update_column(:email, "")
  end

  after do
    $redis.del(described_class::LAST_PROCESSED_USER_ID_KEY)
  end

  it "enqueues the email only for eligible verified users" do
    expect do
      described_class.new.process
    end.to have_enqueued_mail(CreatorMailer, :top_creator_announcement).with(user_id: @verified_user_1.id).once
       .and have_enqueued_mail(CreatorMailer, :top_creator_announcement).with(user_id: @verified_user_2.id).once
       .and have_enqueued_mail(CreatorMailer, :top_creator_announcement).with(user_id: @unverified_user.id).exactly(0).times
       .and have_enqueued_mail(CreatorMailer, :top_creator_announcement).with(user_id: @deleted_user.id).exactly(0).times
       .and have_enqueued_mail(CreatorMailer, :top_creator_announcement).with(user_id: @suspended_user.id).exactly(0).times
       .and have_enqueued_mail(CreatorMailer, :top_creator_announcement).with(user_id: @no_email_user.id).exactly(0).times
  end

  it "tracks the last processed user id in Redis" do
    described_class.new.process
    expect($redis.get(described_class::LAST_PROCESSED_USER_ID_KEY).to_i).to eq @verified_user_2.id
  end

  context "when re-run after partial completion" do
    before do
      $redis.set(described_class::LAST_PROCESSED_USER_ID_KEY, @verified_user_1.id)
    end

    it "skips already-processed users" do
      expect do
        described_class.new.process
      end.to have_enqueued_mail(CreatorMailer, :top_creator_announcement).with(user_id: @verified_user_1.id).exactly(0).times
         .and have_enqueued_mail(CreatorMailer, :top_creator_announcement).with(user_id: @verified_user_2.id).once
    end
  end

  describe ".reset_last_processed_user_id" do
    it "clears the Redis checkpoint" do
      $redis.set(described_class::LAST_PROCESSED_USER_ID_KEY, 123)
      described_class.reset_last_processed_user_id
      expect($redis.get(described_class::LAST_PROCESSED_USER_ID_KEY)).to be_nil
    end
  end
end
