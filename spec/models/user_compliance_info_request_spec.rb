# frozen_string_literal: true

require "spec_helper"

describe UserComplianceInfoRequest do
  describe "only_needs_field_to_be_partially_provided" do
    let(:request_1) { create(:user_compliance_info_request, only_needs_field_to_be_partially_provided: true) }
    let(:request_2) { create(:user_compliance_info_request, only_needs_field_to_be_partially_provided: false) }
    let(:request_3) { create(:user_compliance_info_request, only_needs_field_to_be_partially_provided: true) }
    let(:request_4) { create(:user_compliance_info_request, only_needs_field_to_be_partially_provided: false) }
    let(:request_5) { create(:user_compliance_info_request, only_needs_field_to_be_partially_provided: nil) }

    before do
      request_1
      request_2
      request_3
      request_4
      request_5
    end

    describe "no parameter given" do
      it "returns the requests that only need the field to be partially provided" do
        expect(described_class.only_needs_field_to_be_partially_provided).to eq([request_1, request_3])
      end
    end

    describe "true given" do
      it "returns the requests that only need the field to be partially provided" do
        expect(described_class.only_needs_field_to_be_partially_provided(true)).to eq([request_1, request_3])
      end
    end

    describe "false given" do
      it "returns the requests that don't only need the field to be partially provided" do
        expect(described_class.only_needs_field_to_be_partially_provided(false)).to eq([request_2, request_4, request_5])
      end
    end
  end

  describe "emails_sent_at" do
    let(:request) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME) }
    let(:request_email_sent_at) { Time.current }

    before do
      request.record_email_sent!(request_email_sent_at)
    end

    it "returns an array of times when emails had been sent at" do
      request_fresh = UserComplianceInfoRequest.find(request.id)
      expect(request_fresh.emails_sent_at).to eq([request_email_sent_at.change(usec: 0)])
      expect(request_fresh.emails_sent_at[0]).to be_a(Time)
    end
  end

  describe "last_email_sent_at" do
    let(:request) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME) }

    describe "multiple email sent ats have been have been recorded" do
      let(:request_email_sent_at_1) { 2.days.ago }
      let(:request_email_sent_at_2) { 1.day.ago }

      before do
        request.record_email_sent!(request_email_sent_at_1)
        request.record_email_sent!(request_email_sent_at_2)
      end

      it "returns an array of times when emails had been sent at" do
        expect(request.last_email_sent_at).to be_within(1.second).of(request_email_sent_at_2)
      end
    end
  end

  describe "record_email_sent!" do
    let(:request) { create(:user_compliance_info_request, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME) }

    describe "with no parameters" do
      let(:time_now) { Time.current }

      before do
        request.record_email_sent!
        travel_to(time_now) do
          request.record_email_sent!
        end
      end

      it "appends the time now to the list of email sent at times" do
        expect(request.emails_sent_at[1]).to be_within(1.second).of(time_now)
      end
    end

    describe "with a time" do
      let(:time_provided) { Time.current }

      before do
        request.record_email_sent!
        request.record_email_sent!(time_provided)
      end

      it "appends the time provided to the list of email sent at times" do
        expect(request.emails_sent_at[1]).to be_within(1.second).of(time_provided)
      end
    end
  end

  describe "handle_new_user_compliance_info" do
    let(:user) { create(:user) }
    let(:request_1) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::FIRST_NAME) }
    let(:request_2) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::LAST_NAME) }
    let(:request_3) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::NAME) }
    let(:request_4) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID) }
    let(:request_5) do
      create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::TAX_ID,
                                            only_needs_field_to_be_partially_provided: true)
    end
    let(:request_6) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::TAX_ID) }
    let(:request_7) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::BANK_ACCOUNT) }
    let(:user_compliance_info) do
      create(:user_compliance_info_empty, user:,
                                          first_name: "Maxwell", last_name: "Dudeswell", individual_tax_id: "1234", business_tax_id: "")
    end

    before do
      request_1
      request_2
      request_3
      request_4
      request_5
      request_6
      request_7
      user_compliance_info
    end

    it "marks provided any outstanding request for a field not blank" do
      expect(request_1.reload.state).to eq("provided")
      expect(request_2.reload.state).to eq("provided")
    end

    it "sets the provided at for requests that are closed" do
      expect(request_1.reload.provided_at).not_to be_nil
      expect(request_1.reload.provided_at).to be_a(Time)
      expect(request_2.reload.provided_at).not_to be_nil
      expect(request_2.reload.provided_at).to be_a(Time)
    end

    it "does not change any outstanding request for fields not provided" do
      expect(request_3.reload.state).to eq("requested")
    end

    it "marks provided any outstanding request for an encrypted field" do
      expect(request_6.reload.state).to eq("requested")
      expect(request_7.reload.state).to eq("requested")
    end

    it "marks provided any outstanding request for a field not blank partially provided" do
      expect(request_4.reload.state).to eq("provided")
      expect(request_5.reload.state).to eq("provided")
    end

    describe "field has an expected length and can be partially provided" do
      let(:user_compliance_info) do
        create(:user_compliance_info_empty, user:,
                                            country: "United States", first_name: "Maxwell", last_name: "Dudeswell", individual_tax_id: "1234", business_tax_id: "")
      end

      it "marks provided any outstanding request for a field not blank partially provided" do
        expect(request_4.reload.state).to eq("requested")
        expect(request_5.reload.state).to eq("provided")
      end
    end

    describe "field has an expected length and can be partially provided, but is provided in full" do
      let(:user_compliance_info) do
        create(:user_compliance_info_empty, user:,
                                            country: "United States", first_name: "Maxwell", last_name: "Dudeswell", individual_tax_id: "123456789", business_tax_id: "")
      end

      it "marks provided any outstanding request for a field not blank partially provided" do
        expect(request_4.reload.state).to eq("provided")
        expect(request_5.reload.state).to eq("provided")
      end
    end

    describe "field has an expected length and can be partially provided and has separators in it" do
      let(:user_compliance_info) do
        create(:user_compliance_info_empty, user:,
                                            country: "United States", first_name: "Maxwell", last_name: "Dudeswell", individual_tax_id: "12-34", business_tax_id: "")
      end

      it "marks provided any outstanding request for a field not blank partially provided" do
        expect(request_4.reload.state).to eq("requested")
        expect(request_5.reload.state).to eq("provided")
      end
    end
  end

  describe "handle_new_bank_account" do
    let(:user) { create(:user) }
    let(:request_1) { create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::BANK_ACCOUNT) }
    let(:bank_account) { create(:ach_account, user:) }

    before do
      request_1
      bank_account
    end

    it "marks provided any outstanding request for a bank account" do
      expect(request_1.reload.state).to eq("provided")
    end
  end
end
