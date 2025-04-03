# frozen_string_literal: true

require "spec_helper"

describe SendRemindersForOutstandingUserComplianceInfoRequestsWorker do
  describe "#perform" do
    let(:user_1) { create(:user) }
    let(:user_2) { create(:user) }
    let(:user_3) { create(:user) }
    let(:user_4) { create(:user) }
    let(:user_5) { create(:user) }
    let(:user_6) { create(:user) }
    let(:user_7) { create(:user) }
    let(:user_8) { create(:user, deleted_at: 1.minute.ago) }
    let(:user_9) do
      user = create(:user)
      admin = create(:admin_user)
      user.flag_for_fraud!(author_id: admin.id)
      user.suspend_for_fraud!(author_id: admin.id)
      user
    end

    let!(:user_1_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME, user: user_1) }
    let!(:user_1_request_2) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::LAST_NAME, user: user_1) }
    let!(:user_1_request_3) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::TAX_ID, user: user_1) }
    let!(:user_2_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::TAX_ID, user: user_2) }
    let!(:user_3_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::TAX_ID, user: user_3) }
    let!(:user_4_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::TAX_ID, user: user_4) }
    let!(:user_5_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::TAX_ID, user: user_5) }
    let!(:user_6_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME, user: user_6) }
    let!(:user_6_request_2) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::LAST_NAME, user: user_6) }
    let!(:user_7_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::TAX_ID, user: user_7) }
    let!(:user_8_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME, user: user_8) }
    let!(:user_9_request_1) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME, user: user_9) }

    let(:time_now) { Time.current.change(usec: 0) }

    before do
      travel_to(time_now)
    end

    before do
      user_2_request_1.record_email_sent!(Time.current)
      user_3_request_1.record_email_sent!(1.day.ago)
      user_4_request_1.record_email_sent!(2.days.ago)
      user_5_request_1.record_email_sent!(3.days.ago)
      user_6_request_1.record_email_sent!(3.days.ago)
      user_7_request_1.record_email_sent!(10.days.ago)
      user_7_request_1.record_email_sent!(8.days.ago)

      described_class.new.perform

      user_1_request_1.reload
      user_1_request_2.reload
      user_1_request_3.reload
      user_2_request_1.reload
      user_3_request_1.reload
      user_4_request_1.reload
      user_5_request_1.reload
      user_6_request_1.reload
      user_6_request_2.reload
      user_7_request_1.reload
    end

    it "reminds a user of all the outstanding requests, if they have never been reminded" do
      expect(user_1_request_1.emails_sent_at).to eq([Time.current])
      expect(user_1_request_2.emails_sent_at).to eq([Time.current])
      expect(user_1_request_3.emails_sent_at).to eq([Time.current])
    end

    it "does not remind a user who was just reminded" do
      expect(user_2_request_1.emails_sent_at).to eq([Time.current])
    end

    it "does not remind a user who was reminded less than 2 days ago" do
      expect(user_3_request_1.emails_sent_at).to eq([1.day.ago])
    end

    it "does not remind a user who was reminded 2 days ago" do
      expect(user_4_request_1.emails_sent_at).to eq([2.days.ago])
    end

    it "reminds a user who was reminded more than 2 days ago" do
      expect(user_5_request_1.emails_sent_at).to eq([3.days.ago, Time.current])
      expect(user_6_request_1.emails_sent_at).to eq([3.days.ago, Time.current])
      expect(user_6_request_2.emails_sent_at).to eq([Time.current])
    end

    it "does not remind a user who was reminded twice already" do
      expect(user_7_request_1.emails_sent_at).to eq([10.days.ago, 8.days.ago])
    end

    it "does not remind a deleted user" do
      expect(user_8_request_1.emails_sent_at).to be_empty
    end

    it "does not remind a suspended user" do
      expect(user_9_request_1.emails_sent_at).to be_empty
    end
  end

  describe "singapore identity verification requests", :vcr do
    before do
      @user = create(:user)
      create(:merchant_account, user: @user, country: "SG")
      @sg_verification_request = create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::STRIPE_ENHANCED_IDENTITY_VERIFICATION, user: @user)
    end

    it "reminds a user of the outstanding request if they have never been reminded" do
      described_class.new.perform

      expect(Time.zone.parse(@sg_verification_request.reload.sg_verification_reminder_sent_at)).to eq(Time.current.change(usec: 0))
    end

    it "does not remind a user who was reminded less than 7 days ago" do
      @sg_verification_request.sg_verification_reminder_sent_at = 6.days.ago
      @sg_verification_request.save!

      described_class.new.perform

      expect(Time.zone.parse(@sg_verification_request.reload.sg_verification_reminder_sent_at)).to eq(6.days.ago.change(usec: 0))
    end

    it "reminds a user who was reminded more than 7 days ago" do
      @sg_verification_request.sg_verification_reminder_sent_at = 8.days.ago
      @sg_verification_request.save!

      described_class.new.perform

      expect(Time.zone.parse(@sg_verification_request.reload.sg_verification_reminder_sent_at)).to eq(Time.current.change(usec: 0))
    end

    it "does not remind a user if their account was created more than 120 days ago" do
      user = create(:user)
      create(:merchant_account, user:, country: "SG", created_at: 121.days.ago)
      sg_verification_request = create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::STRIPE_ENHANCED_IDENTITY_VERIFICATION, user:)

      described_class.new.perform

      expect(sg_verification_request.reload.sg_verification_reminder_sent_at).to be_nil
    end

    it "does not remind a deleted user" do
      @user.update!(deleted_at: 1.minute.ago)

      described_class.new.perform

      expect(@sg_verification_request.reload.sg_verification_reminder_sent_at).to be_nil
    end

    it "does not remind a suspended user" do
      @user.flag_for_fraud!(author_id: @user.id)
      @user.suspend_for_fraud!(author_id: @user.id)

      described_class.new.perform

      expect(@sg_verification_request.reload.sg_verification_reminder_sent_at).to be_nil
    end

    it "does not remind if user's current stripe account is not a singapore account" do
      user = create(:user)
      sg_verification_request = create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::STRIPE_ENHANCED_IDENTITY_VERIFICATION, user:)
      create(:merchant_account, user:, country: "US")

      described_class.new.perform

      expect(sg_verification_request.reload.sg_verification_reminder_sent_at).to be_nil
    end
  end
end
