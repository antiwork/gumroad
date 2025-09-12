# frozen_string_literal: true

require "spec_helper"

describe Onetime::NotifySellersAboutPaypalPayoutsRemoval do
  before do
    @eligible_seller_1 = create(:user_with_compliance_info)
    create(:payment_completed, user: @eligible_seller_1, created_at: Date.new(2025, 2, 10))

    @eligible_seller_2 = create(:user)
    create(:user_compliance_info_singapore, user: @eligible_seller_2)
    create(:payment_completed, user: @eligible_seller_2, created_at: Date.new(2025, 7, 7))

    @eligible_seller_3 = create(:user)
    create(:user_compliance_info_canada, user: @eligible_seller_3)
    create(:payment_completed, user: @eligible_seller_3, created_at: Date.new(2025, 2, 5))

    @eligible_seller_4 = create(:user)
    create(:user_compliance_info, country: "France", user: @eligible_seller_4)
    create(:payment_completed, user: @eligible_seller_4, created_at: Date.new(2025, 4, 15))

    @ineligible_seller_1 = create(:user)
    create(:user_compliance_info_uae, user: @ineligible_seller_1)
    create(:payment_completed, user: @ineligible_seller_1, created_at: Date.new(2025, 5, 20))

    @ineligible_seller_2 = create(:user)
    create(:user_compliance_info, user: @ineligible_seller_2, country: "India")
    create(:payment_completed, user: @ineligible_seller_2, created_at: Date.new(2025, 3, 25))

    @ineligible_seller_3 = create(:user_with_compliance_info)
    create(:payment_completed,
           user: @ineligible_seller_3,
           processor: PayoutProcessorType::STRIPE,
           stripe_transfer_id: "t_12345",
           stripe_connect_account_id: "acct_12345",
           created_at: Date.new(2025, 3, 25))

    @ineligible_seller_4 = create(:user_with_compliance_info)
    create(:payment_completed, user: @ineligible_seller_4, created_at: Date.new(2024, 12, 31))

    @ineligible_seller_5 = create(:user_with_compliance_info)
    create(:payment_failed, user: @ineligible_seller_5, created_at: Date.new(2025, 5, 20))

    @ineligible_seller_6 = create(:user_with_compliance_info)
  end

  it "enqueues the email for correct sellers with proper arguments" do
    expect do
      described_class.process
    end.to have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@eligible_seller_1.id).once
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@eligible_seller_2.id).once
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@eligible_seller_3.id).once
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@eligible_seller_4.id).once
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_1.id).exactly(0).times
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_2.id).exactly(0).times
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_3.id).exactly(0).times
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_4.id).exactly(0).times
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_5.id).exactly(0).times
       .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_6.id).exactly(0).times

    expect($redis.get("notified_paypal_removal_till_user_id").to_i).to eq @eligible_seller_4.id
  end

  context "when email has already been sent to some sellers" do
    before do
      $redis.set("notified_paypal_removal_till_user_id", @eligible_seller_2.id)
    end

    it "does not enqueue for sellers who have already been sent the email" do
      expect($redis.get("notified_paypal_removal_till_user_id").to_i).to eq @eligible_seller_2.id

      expect do
        described_class.process
      end.to have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@eligible_seller_1.id).exactly(0).times
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@eligible_seller_2.id).exactly(0).times
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@eligible_seller_3.id).once
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@eligible_seller_4.id).once
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_1.id).exactly(0).times
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_2.id).exactly(0).times
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_3.id).exactly(0).times
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_4.id).exactly(0).times
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_5.id).exactly(0).times
         .and have_enqueued_mail(ContactingCreatorMailer, :paypal_suspension_notification).with(@ineligible_seller_6.id).exactly(0).times

      expect($redis.get("notified_paypal_removal_till_user_id").to_i).to eq @eligible_seller_4.id
    end
  end
end
