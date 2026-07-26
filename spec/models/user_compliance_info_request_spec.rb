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

  describe "#verification_error_message" do
    let(:user) { create(:user) }
    let(:request) do
      create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Business::STRIPE_COMPANY_DOCUMENT_ID)
    end

    def set_error(code)
      request.verification_error = { "code" => code }
      request.save!
    end

    context "when the seller has never given us a P.O. Box address" do
      before { create(:user_compliance_info_business, user:) }

      it "returns the standard address mismatch copy" do
        set_error("verification_document_address_mismatch")

        expect(request.reload.verification_error_message).to include("upload a document with address that matches the account")
        expect(request.reload.verification_error_message).not_to include("P.O. Box")
      end
    end

    context "when the seller's registered address is a P.O. Box" do
      before { create(:user_compliance_info_business, user:, business_street_address: "PO Box 65") }

      it "explains the deadlock instead of asking for another upload" do
        set_error("verification_document_address_mismatch")

        expect(request.reload.verification_error_message).to eq(described_class::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)
      end

      it "explains the deadlock for the keyed address match failure too" do
        set_error("verification_failed_address_match")

        expect(request.reload.verification_error_message).to eq(described_class::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)
      end

      it "still explains the deadlock once the P.O. Box has been edited off the account" do
        # This is the real-world sequence: the P.O. Box is rejected on the account, the seller
        # replaces it with something our payment partner accepts, and only then does the document
        # get rejected for not matching. The P.O. Box only survives in the older revisions.
        create(:user_compliance_info_business, user:, business_street_address: "NW-22-34-19-W2")
        set_error("verification_document_address_mismatch")

        expect(request.reload.verification_error_message).to eq(described_class::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)
      end

      it "leaves unrelated rejection reasons alone" do
        set_error("verification_document_expired")

        expect(request.reload.verification_error_message).to include("issue or expiry date")
      end

      it "overrides the reason our payment partner supplied, because that reason is the misleading one" do
        request.verification_error = {
          "code" => "verification_document_address_mismatch",
          "message" => "Address on the account doesn't match the verification document."
        }
        request.save!

        expect(request.reload.verification_error_message).to eq(described_class::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)
      end
    end

    context "when the P.O. Box is only in an individual address" do
      before { create(:user_compliance_info, user:, street_address: "P.O. Box 65") }

      it "explains the deadlock" do
        set_error("verification_document_address_mismatch")

        expect(request.reload.verification_error_message).to eq(described_class::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)
      end
    end

    context "when the seller wrote their post office box without the words 'PO Box'" do
      # How a rural seller with no civic street address normally writes it. This is the exact
      # population the deadlock hits hardest, so the messaging has to recognise the form.
      before { create(:user_compliance_info_business, user:, business_street_address: "Box 65, RR 2") }

      it "explains the deadlock" do
        set_error("verification_document_address_mismatch")

        expect(request.reload.verification_error_message).to eq(described_class::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)
      end
    end

    context "when many later compliance edits sit on top of the P.O. Box revision" do
      before do
        create(:user_compliance_info_business, user:, business_street_address: "PO Box 65")
        # Compliance revisions are created for edits to any field, not just the address. A seller
        # who keeps correcting their phone number after replacing the P.O. Box must not lose the
        # explanation to a recency cutoff.
        30.times do |index|
          create(:user_compliance_info_business, user:, business_street_address: "NW-22-34-19-W2", phone: "555-01#{index.to_s.rjust(2, '0')}")
        end
      end

      it "still explains the deadlock" do
        set_error("verification_document_address_mismatch")

        expect(request.reload.verification_error_message).to eq(described_class::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)
      end
    end
  end
end
