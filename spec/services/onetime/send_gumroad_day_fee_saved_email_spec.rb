# frozen_string_literal: true

require "spec_helper"

describe Onetime::SendGumroadDayFeeSavedEmail do
  before do
    @eligible_seller_1 = create(:user, gumroad_day_timezone: "Pacific Time (US & Canada)")
    create(:purchase,
           price_cents: 206_20,
           link: create(:product, user: @eligible_seller_1),
           created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "-07:00"))

    @eligible_seller_2 = create(:user, gumroad_day_timezone: "Mumbai")
    create(:purchase,
           price_cents: 106_20,
           link: create(:product, user: @eligible_seller_2),
           created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "+05:30"))

    @ineligible_seller_1 = create(:user, timezone: "Melbourne")
    create(:purchase,
           price_cents: 206_20,
           link: create(:product, user: @ineligible_seller_1),
           created_at: DateTime.new(2024, 4, 3, 12, 0, 0, "+11:00"))

    @ineligible_seller_2 = create(:user, gumroad_day_timezone: "Pacific Time (US & Canada)")
    create(:free_purchase,
           link: create(:product, user: @ineligible_seller_2),
           created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "-07:00"))

    @eligible_seller_3 = create(:user, gumroad_day_timezone: "Melbourne")
    create(:purchase,
           price_cents: 100_00,
           link: create(:product, user: @eligible_seller_3),
           created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "+11:00"))

    @eligible_seller_4 = create(:user, gumroad_day_timezone: "UTC")
    create(:purchase,
           price_cents: 10_00,
           link: create(:product, user: @eligible_seller_4),
           created_at: DateTime.new(2024, 4, 4, 12, 0, 0))

    @eligible_seller_5 = create(:user, gumroad_day_timezone: "Eastern Time (US & Canada)")
    create(:purchase,
           price_cents: 25_00,
           link: create(:product, user: @eligible_seller_5),
           created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "-04:00"))
  end

  it "enqueues the email for correct users with proper arguments" do
    expect do
      described_class.process
    end.to have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_1.id).once
       .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_2.id).once
       .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_3.id).once
       .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_4.id).once
       .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_5.id).once
       .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @ineligible_seller_1.id).exactly(0).times
       .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @ineligible_seller_2.id).exactly(0).times

    expect($redis.get("gumroad_day_fee_saved_email_last_user_id").to_i).to eq @eligible_seller_5.id
  end

  context "when email has already been sent to some users" do
    before do
      $redis.set("gumroad_day_fee_saved_email_last_user_id", @eligible_seller_3.id)
    end

    it "does not enqueue for users who have already been sent the email" do
      expect($redis.get("gumroad_day_fee_saved_email_last_user_id").to_i).to eq @eligible_seller_3.id

      expect do
        described_class.process
      end.to have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_1.id).exactly(0).times
         .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_2.id).exactly(0).times
         .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_3.id).exactly(0).times
         .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_4.id).once
         .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @eligible_seller_5.id).once
         .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @ineligible_seller_1.id).exactly(0).times
         .and have_enqueued_mail(CreatorMailer, :gumroad_day_fee_saved).with(seller_id: @ineligible_seller_2.id).exactly(0).times

      expect($redis.get("gumroad_day_fee_saved_email_last_user_id").to_i).to eq @eligible_seller_5.id
    end
  end
end
