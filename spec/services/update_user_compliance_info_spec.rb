# frozen_string_literal: true

require "spec_helper"

RSpec.describe UpdateUserComplianceInfo do
  let(:user) { create(:user) }
  let(:remote_ip) { "192.168.1.1" }

  before do
    create(:user_compliance_info, user: user, birthday: 16.years.ago.to_date)
  end

  describe "#process" do
    context "with guardian params" do
      let(:guardian_params) do
        {
          guardian_first_name: "John",
          guardian_last_name: "Guardian",
          guardian_email: "guardian@example.com",
          guardian_phone: "+1234567890",
          guardian_street_address: "123 Guardian St",
          guardian_city: "Guardian City",
          guardian_state: "CA",
          guardian_zip_code: "90210",
          guardian_country: "US",
          guardian_dob_year: "1980",
          guardian_dob_month: "6",
          guardian_dob_day: "15",
          guardian_individual_tax_id: "123456789",
          guardian_stripe_tos_accepted: "true",
          guardian_stripe_processing_tos_accepted: "true"
        }
      end

      it "creates a guardian record" do
        service = described_class.new(compliance_params: guardian_params, user: user, remote_ip: remote_ip)

        expect { service.process }.to change { Guardian.count }.by(1)

        guardian = user.reload.guardian
        expect(guardian.first_name).to eq("John")
        expect(guardian.last_name).to eq("Guardian")
        expect(guardian.email).to eq("guardian@example.com")
        expect(guardian.phone).to eq("+1234567890")
        expect(guardian.street_address).to eq("123 Guardian St")
        expect(guardian.city).to eq("Guardian City")
        expect(guardian.state).to eq("CA")
        expect(guardian.zip_code).to eq("90210")
        expect(guardian.country).to eq("United States")
        expect(guardian.date_of_birth).to eq(Date.new(1980, 6, 15))
        expect(guardian.stripe_tos_accepted).to eq(true)
        expect(guardian.stripe_tos_ip).to eq(remote_ip)
        expect(guardian.stripe_processing_tos_accepted).to eq(true)
      end

      it "updates an existing guardian record" do
        existing_guardian = create(:guardian, user: user, first_name: "Old", last_name: "Name")
        service = described_class.new(compliance_params: guardian_params, user: user, remote_ip: remote_ip)

        expect { service.process }.not_to change { Guardian.count }

        existing_guardian.reload
        expect(existing_guardian.first_name).to eq("John")
        expect(existing_guardian.last_name).to eq("Guardian")
      end

      it "returns success" do
        service = described_class.new(compliance_params: guardian_params, user: user, remote_ip: remote_ip)

        result = service.process

        expect(result[:success]).to eq(true)
      end
    end

    context "with guardian validation errors" do
      it "returns error when guardian is under 18" do
        params = {
          guardian_first_name: "Young",
          guardian_last_name: "Guardian",
          guardian_dob_year: (Date.current.year - 10).to_s,
          guardian_dob_month: "1",
          guardian_dob_day: "1"
        }

        service = described_class.new(compliance_params: params, user: user, remote_ip: remote_ip)
        result = service.process

        expect(result[:success]).to eq(false)
        expect(result[:error_message]).to include("18 years old")
      end
    end

    context "with transaction safety" do
      it "rolls back guardian changes when guardian save fails" do
        params = {
          first_name: "Updated",
          guardian_first_name: "John",
          guardian_last_name: "Guardian",
          guardian_dob_year: (Date.current.year - 10).to_s,
          guardian_dob_month: "1",
          guardian_dob_day: "1"
        }

        service = described_class.new(compliance_params: params, user: user, remote_ip: remote_ip)
        result = service.process

        expect(result[:success]).to eq(false)
        expect(Guardian.where(user: user).count).to eq(0)
      end
    end

    context "without guardian params" do
      it "does not create a guardian record" do
        params = { first_name: "Updated" }

        service = described_class.new(compliance_params: params, user: user, remote_ip: remote_ip)

        expect { service.process }.not_to change { Guardian.count }
      end
    end

    context "with country-specific guardian fields" do
      it "saves Japanese name fields" do
        params = {
          guardian_first_name: "John",
          guardian_last_name: "Guardian",
          guardian_first_name_kanji: "山田",
          guardian_last_name_kanji: "太郎",
          guardian_first_name_kana: "ヤマダ",
          guardian_last_name_kana: "タロウ",
          guardian_dob_year: "1980",
          guardian_dob_month: "6",
          guardian_dob_day: "15"
        }

        service = described_class.new(compliance_params: params, user: user, remote_ip: remote_ip)
        service.process

        guardian = user.reload.guardian
        expect(guardian.first_name_kanji).to eq("山田")
        expect(guardian.last_name_kanji).to eq("太郎")
        expect(guardian.first_name_kana).to eq("ヤマダ")
        expect(guardian.last_name_kana).to eq("タロウ")
      end

      it "saves job title and nationality" do
        params = {
          guardian_first_name: "John",
          guardian_last_name: "Guardian",
          guardian_job_title: "Software Engineer",
          guardian_nationality: "US",
          guardian_dob_year: "1980",
          guardian_dob_month: "6",
          guardian_dob_day: "15"
        }

        service = described_class.new(compliance_params: params, user: user, remote_ip: remote_ip)
        service.process

        guardian = user.reload.guardian
        expect(guardian.job_title).to eq("Software Engineer")
        expect(guardian.nationality).to eq("US")
      end
    end

    context "with empty params" do
      it "returns success without creating anything" do
        service = described_class.new(compliance_params: {}, user: user, remote_ip: remote_ip)

        result = service.process

        expect(result[:success]).to eq(true)
      end

      it "returns success with nil params" do
        service = described_class.new(compliance_params: nil, user: user, remote_ip: remote_ip)

        result = service.process

        expect(result[:success]).to eq(true)
      end
    end
  end

  describe "#has_guardian_params?" do
    it "returns true when guardian params present" do
      params = { guardian_first_name: "John" }
      service = described_class.new(compliance_params: params, user: user)

      expect(service.send(:has_guardian_params?)).to eq(true)
    end

    it "returns false when no guardian params present" do
      params = { first_name: "John" }
      service = described_class.new(compliance_params: params, user: user)

      expect(service.send(:has_guardian_params?)).to eq(false)
    end

    it "returns false when guardian params are blank" do
      params = { guardian_first_name: "" }
      service = described_class.new(compliance_params: params, user: user)

      expect(service.send(:has_guardian_params?)).to eq(false)
    end
  end
end
