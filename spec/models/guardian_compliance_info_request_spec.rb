# frozen_string_literal: true

require "spec_helper"

RSpec.describe GuardianComplianceInfoRequest, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:user) }
  end

  describe "state machine" do
    let(:user) { create(:user) }
    let(:request) { create(:guardian_compliance_info_request, user: user, state: "requested") }

    it "has initial state of requested" do
      new_request = build(:guardian_compliance_info_request, user: user)
      expect(new_request.state).to eq("requested")
    end

    describe "mark_provided event" do
      it "transitions from requested to provided" do
        expect(request.state).to eq("requested")
        
        request.mark_provided!
        
        expect(request.state).to eq("provided")
        expect(request.provided_at).to be_present
        expect(request.provided_at).to be_within(1.second).of(Time.current)
      end

      it "sets provided_at timestamp on transition" do
        freeze_time = Time.parse("2024-01-15 10:30:00 UTC")
        
        travel_to freeze_time do
          request.mark_provided!
          expect(request.provided_at).to eq(freeze_time)
        end
      end
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }
    let!(:requested_request) { create(:guardian_compliance_info_request, user: user, state: "requested") }
    let!(:provided_request) { create(:guardian_compliance_info_request, user: user, state: "provided") }

    describe ".requested" do
      it "returns only requested requests" do
        expect(described_class.requested).to contain_exactly(requested_request)
      end
    end

    describe ".provided" do
      it "returns only provided requests" do
        expect(described_class.provided).to contain_exactly(provided_request)
      end
    end
  end

  describe "json data accessors" do
    let(:user) { create(:user) }
    let(:request) { create(:guardian_compliance_info_request, user: user) }

    describe "#stripe_event_id" do
      it "stores and retrieves stripe event ID" do
        request.stripe_event_id = "evt_1234567890"
        request.save!
        
        request.reload
        expect(request.stripe_event_id).to eq("evt_1234567890")
      end
    end

    describe "#guardian_person_id" do
      it "stores and retrieves guardian person ID" do
        request.guardian_person_id = "person_1234567890"
        request.save!
        
        request.reload
        expect(request.guardian_person_id).to eq("person_1234567890")
      end
    end

    describe "#verification_error" do
      it "stores and retrieves verification error messages" do
        error_message = "Document verification failed"
        request.verification_error = error_message
        request.save!
        
        request.reload
        expect(request.verification_error).to eq(error_message)
      end
    end
  end

  describe "#emails_sent_at" do
    let(:user) { create(:user) }
    let(:request) { create(:guardian_compliance_info_request, user: user) }

    it "returns empty array by default" do
      expect(request.emails_sent_at).to eq([])
    end

    it "parses string timestamps to Time objects" do
      timestamp = "2024-01-15T10:30:00Z"
      request.emails_sent_at = [timestamp]
      request.save!
      
      request.reload
      expect(request.emails_sent_at.first).to be_a(Time)
      expect(request.emails_sent_at.first).to eq(Time.parse(timestamp))
    end

    it "handles Time objects directly" do
      timestamp = Time.current
      request.emails_sent_at = [timestamp]
      request.save!
      
      request.reload
      expect(request.emails_sent_at.first).to be_a(Time)
      expect(request.emails_sent_at.first).to be_within(1.second).of(timestamp)
    end

    it "handles mixed string and Time objects" do
      string_time = "2024-01-15T10:30:00Z"
      time_object = Time.current
      request.emails_sent_at = [string_time, time_object]
      request.save!
      
      request.reload
      expect(request.emails_sent_at).to all(be_a(Time))
      expect(request.emails_sent_at.first).to eq(Time.parse(string_time))
      expect(request.emails_sent_at.last).to be_within(1.second).of(time_object)
    end
  end

  describe "#record_email_sent!" do
    let(:user) { create(:user) }
    let(:request) { create(:guardian_compliance_info_request, user: user) }

    it "records current time by default" do
      current_time = Time.current
      
      travel_to current_time do
        request.record_email_sent!
        
        expect(request.emails_sent_at.last).to be_within(1.second).of(current_time)
      end
    end

    it "records specific timestamp when provided" do
      specific_time = Time.parse("2024-01-15T10:30:00Z")
      
      request.record_email_sent!(specific_time)
      
      expect(request.emails_sent_at).to include(specific_time)
    end

    it "appends to existing timestamps" do
      first_time = Time.parse("2024-01-15T10:30:00Z")
      second_time = Time.parse("2024-01-16T10:30:00Z")
      
      request.record_email_sent!(first_time)
      request.record_email_sent!(second_time)
      
      expect(request.emails_sent_at).to contain_exactly(first_time, second_time)
    end

    it "persists the change to database" do
      timestamp = Time.current.change(usec: 0)
      
      request.record_email_sent!(timestamp)
      
      request.reload
      expect(request.emails_sent_at).to include(timestamp)
    end
  end

  describe "flag handling" do
    let(:user) { create(:user) }
    let(:request) { create(:guardian_compliance_info_request, user: user) }

    describe "#only_needs_field_to_be_partially_provided?" do
      it "defaults to false" do
        expect(request.only_needs_field_to_be_partially_provided?).to eq(false)
      end

      it "can be set to true" do
        request.only_needs_field_to_be_partially_provided = true
        request.save!
        
        request.reload
        expect(request.only_needs_field_to_be_partially_provided?).to eq(true)
      end
    end
  end

  describe ".handle_new_guardian_compliance_info" do
    let(:user) { create(:user_with_compliance_info) }
    let(:user_compliance_info) { user.alive_user_compliance_info }

    before do
      # Mock the global config for encryption
      allow(GlobalConfig).to receive(:get).with("STRONGBOX_GENERAL_PASSWORD").and_return("test_password")
      
      # Mock Strongbox::Lock behavior to avoid encryption issues in tests
      allow_any_instance_of(Strongbox::Lock).to receive(:decrypt).and_return("decrypted_value")
    end

    context "when guardian compliance info requests exist" do
      let!(:first_name_request) do
        create(:guardian_compliance_info_request,
          user: user,
          field_needed: "guardian_first_name",
          state: "requested"
        )
      end

      let!(:last_name_request) do
        create(:guardian_compliance_info_request,
          user: user,
          field_needed: "guardian_last_name",
          state: "requested"
        )
      end

      let!(:email_request) do
        create(:guardian_compliance_info_request,
          user: user,
          field_needed: "guardian_email",
          state: "requested"
        )
      end

      it "marks matching requests as provided when fields are filled" do
        saved, new_compliance_info = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_first_name = "John"
          new_info.guardian_last_name = "Guardian"
        end

        described_class.handle_new_guardian_compliance_info(new_compliance_info)

        first_name_request.reload
        last_name_request.reload
        email_request.reload

        expect(first_name_request.state).to eq("provided")
        expect(last_name_request.state).to eq("provided")
        expect(email_request.state).to eq("requested") # email was not provided
      end

      it "handles encrypted fields properly" do
        # Create a request for encrypted tax ID field
        tax_id_request = create(:guardian_compliance_info_request,
          user: user,
          field_needed: "guardian_individual_tax_id",
          state: "requested"
        )

        # Update with encrypted tax ID
        saved, new_compliance_info = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_individual_tax_id = "123456789"
        end

        described_class.handle_new_guardian_compliance_info(new_compliance_info)

        tax_id_request.reload
        expect(tax_id_request.state).to eq("provided")
      end

      it "ignores blank fields" do
        saved, new_compliance_info = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_first_name = ""
          new_info.guardian_last_name = nil
        end

        described_class.handle_new_guardian_compliance_info(new_compliance_info)

        first_name_request.reload
        last_name_request.reload

        expect(first_name_request.state).to eq("requested")
        expect(last_name_request.state).to eq("requested")
      end

      it "handles all defined guardian compliance fields" do
        # Create requests for all guardian fields
        GuardianComplianceInfoFields.all_fields.each do |field|
          create(:guardian_compliance_info_request,
            user: user,
            field_needed: field,
            state: "requested"
          )
        end

        # Update compliance info with sample values for text fields
        saved, new_compliance_info = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_first_name = "John"
          new_info.guardian_last_name = "Guardian"
          new_info.guardian_email = "guardian@example.com"
          new_info.guardian_phone = "+1234567890"
          new_info.guardian_street_address = "123 Guardian St"
          new_info.guardian_city = "Guardian City"
          new_info.guardian_state = "CA"
          new_info.guardian_zip_code = "90210"
          new_info.guardian_country = "US"
          new_info.guardian_dob_day = 15
          new_info.guardian_dob_month = 6
          new_info.guardian_dob_year = 1980
          new_info.guardian_individual_tax_id = "123456789"
        end

        described_class.handle_new_guardian_compliance_info(new_compliance_info)

        # All text field requests should be marked as provided
        text_fields = [
          "guardian_first_name",
          "guardian_last_name", 
          "guardian_email",
          "guardian_phone",
          "guardian_street_address",
          "guardian_city",
          "guardian_state",
          "guardian_zip_code",
          "guardian_country",
          "guardian_dob_day",
          "guardian_dob_month",
          "guardian_dob_year",
          "guardian_individual_tax_id"
        ]

        text_fields.each do |field|
          request = user.guardian_compliance_info_requests.find_by(field_needed: field)
          expect(request&.state).to eq("provided"), "Expected #{field} request to be provided"
        end
      end
    end

    context "when no compliance info requests exist" do
      it "handles gracefully without errors" do
        saved, new_compliance_info = user_compliance_info.dup_and_save do |new_info|
          new_info.guardian_first_name = "John"
        end

        expect {
          described_class.handle_new_guardian_compliance_info(new_compliance_info)
        }.not_to raise_error
      end
    end

    context "when user compliance info has no guardian fields" do
      it "does not mark any requests as provided" do
        request = create(:guardian_compliance_info_request,
          user: user,
          field_needed: "guardian_first_name",
          state: "requested"
        )

        described_class.handle_new_guardian_compliance_info(user_compliance_info)

        request.reload
        expect(request.state).to eq("requested")
      end
    end
  end

  describe "external ID generation" do
    let(:user) { create(:user) }

    before do
      # Mock the global config for encryption
      allow(GlobalConfig).to receive(:get).with("OBFUSCATE_IDS_CIPHER_KEY").and_return("test_key_32_characters_long!!")
    end

    it "generates external ID on creation" do
      request = create(:guardian_compliance_info_request, user: user)
      
      expect(request.external_id).to be_present
      expect(request.external_id.length).to be >= 10
    end

    it "generates unique external IDs" do
      request1 = create(:guardian_compliance_info_request, user: user)
      request2 = create(:guardian_compliance_info_request, user: user)
      
      expect(request1.external_id).not_to eq(request2.external_id)
    end
  end

  describe "field_needed validation" do
    let(:user) { create(:user) }

    it "allows valid guardian compliance field names" do
      valid_fields = [
        "guardian_first_name",
        "guardian_last_name",
        "guardian_email",
        "guardian_phone",
        "guardian_birthday",
        "guardian_individual_tax_id",
        "guardian_street_address",
        "guardian_city",
        "guardian_state",
        "guardian_zip_code",
        "guardian_country"
      ]

      valid_fields.each do |field|
        request = build(:guardian_compliance_info_request, user: user, field_needed: field)
        expect(request).to be_valid, "Expected #{field} to be a valid field_needed value"
      end
    end
  end
end