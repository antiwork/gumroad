# frozen_string_literal: true

require "spec_helper"

describe UpdateUserComplianceInfo do
  describe "#process" do
    let(:user) { create(:user) }

    context "when individual_tax_id exceeds maximum length" do
      it "returns an error without attempting RSA encryption" do
        oversized_tax_id = "1" * 201
        params = ActionController::Parameters.new(individual_tax_id: oversized_tax_id)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Individual tax id is too long")
      end
    end

    context "when business_tax_id exceeds maximum length" do
      it "returns an error without attempting RSA encryption" do
        oversized_tax_id = "1" * 201
        params = ActionController::Parameters.new(business_tax_id: oversized_tax_id)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Business tax id is too long")
      end
    end

    context "when ssn_last_four exceeds maximum length" do
      it "returns an error without attempting RSA encryption" do
        oversized_ssn = "1" * 201
        params = ActionController::Parameters.new(ssn_last_four: oversized_ssn)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Individual tax id is too long")
      end
    end

    context "when individual_tax_id is valid but ssn_last_four exceeds maximum length" do
      it "returns an error before assigning either value" do
        params = ActionController::Parameters.new(individual_tax_id: "123456789", ssn_last_four: "1" * 201)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Individual tax id is too long")
      end
    end

    context "when submitted compliance values match the current compliance info" do
      let!(:compliance_info) { create(:user_compliance_info, user:) }

      it "returns success without creating a new compliance info row or submitting it to Stripe" do
        request = create(:user_compliance_info_request, user:, field_needed: UserComplianceInfoFields::Individual::Address::STREET)
        params = ActionController::Parameters.new(
          first_name: compliance_info.first_name,
          last_name: compliance_info.last_name,
          street_address: compliance_info.street_address,
          city: compliance_info.city,
          state: compliance_info.state,
          zip_code: compliance_info.zip_code,
          country: compliance_info.country_code,
          business_country: compliance_info.country_code,
          is_business: false,
          ssn_last_four: "000000000",
          dob_month: compliance_info.birthday.month.to_s,
          dob_day: compliance_info.birthday.day.to_s,
          dob_year: compliance_info.birthday.year.to_s,
          phone: compliance_info.phone,
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = nil
        expect do
          result = described_class.new(compliance_params: params, user: user).process
        end.not_to change { UserComplianceInfo.count }

        expect(result[:success]).to be true
        expect(user.reload.alive_user_compliance_info.id).to eq(compliance_info.id)
        expect(request.reload.state).to eq("provided")
      end
    end

    context "when submitted compliance values change the current compliance info" do
      let!(:compliance_info) { create(:user_compliance_info, user:) }

      it "creates a new compliance info row and submits it to Stripe" do
        params = ActionController::Parameters.new(first_name: "Morgan")

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info) do |new_compliance_info|
          expect(new_compliance_info.first_name).to eq("Morgan")
        end

        result = nil
        expect do
          result = described_class.new(compliance_params: params, user: user).process
        end.to change { UserComplianceInfo.count }.by(1)

        expect(result[:success]).to be true
        expect(user.reload.alive_user_compliance_info.first_name).to eq("Morgan")
        expect(user.alive_user_compliance_info.id).not_to eq(compliance_info.id)
      end

      it "persists the Japanese city kana fields (city_kana and business_city_kana)" do
        params = ActionController::Parameters.new(
          city_kana: "シブヤク",
          business_city_kana: "チヨダク",
        )

        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: user).process

        expect(result[:success]).to be true
        new_compliance_info = user.reload.alive_user_compliance_info
        expect(new_compliance_info.city_kana).to eq("シブヤク")
        expect(new_compliance_info.business_city_kana).to eq("チヨダク")
      end
    end

    context "with a Japanese individual account" do
      let(:japan_user) { create(:user) }
      let!(:japan_compliance_info) do
        create(
          :user_compliance_info,
          user: japan_user,
          country: "Japan",
          city: nil,
          state: "東京都",
          zip_code: "1130022",
          json_data: {
            street_address_kanji: "文京区千駄木3丁目",
            street_address_kana: "ブンキョウクセンダギ3チョウメ",
            building_number: "1-1",
            building_number_kana: "1-1",
          }
        )
      end

      it "rejects an address submission without a city" do
        params = ActionController::Parameters.new(
          street_address_kanji: "文京区千駄木4丁目",
          street_address_kana: "ブンキョウクセンダギ4チョウメ",
          building_number: "2-2",
          building_number_kana: "2-2",
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = nil
        expect do
          result = described_class.new(compliance_params: params, user: japan_user).process
        end.not_to change { UserComplianceInfo.count }

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("City/Ward is required for Japanese addresses. Please re-enter your address including the city/ward.")
      end

      it "rejects a submission that fills in only one of the city pair" do
        # A direct request (bypassing the form) that sets `city` without `city_kana` would
        # otherwise sync a half-populated address to Stripe.
        params = ActionController::Parameters.new(city: "文京区")

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("City/Ward is required for Japanese addresses. Please re-enter your address including the city/ward.")
      end

      it "rejects a postal-code-only update on a record with no city" do
        # Changing just the postal code (or prefecture) still re-syncs the whole address to
        # Stripe, so it must count as an address change and require the city like any other
        # address edit — otherwise a legacy no-city record can keep updating its address
        # piecemeal without ever entering one.
        params = ActionController::Parameters.new(zip_code: "1130023")

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("City/Ward is required for Japanese addresses. Please re-enter your address including the city/ward.")
      end

      it "accepts an address submission that includes the city fields" do
        params = ActionController::Parameters.new(
          street_address_kanji: "千駄木3丁目",
          street_address_kana: "センダギ3チョウメ",
          building_number: "1-1",
          building_number_kana: "1-1",
          city: "文京区",
          city_kana: "ブンキョウク",
        )

        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_user).process

        expect(result[:success]).to be true
        new_compliance_info = japan_user.reload.alive_user_compliance_info
        expect(new_compliance_info.city).to eq("文京区")
        expect(new_compliance_info.city_kana).to eq("ブンキョウク")
        expect(new_compliance_info.street_address_kanji).to eq("千駄木3丁目")
      end

      it "accepts a full settings-form save that changes only the phone on a legacy record with no city" do
        # The Payments settings form echoes back every stored compliance field on save, so a
        # phone-only change still arrives with the whole stored (city-less) Japanese address.
        # That must not trip the city requirement — the seller didn't touch their address.
        params = ActionController::Parameters.new(
          is_business: false,
          first_name: japan_compliance_info.first_name,
          last_name: japan_compliance_info.last_name,
          street_address: japan_compliance_info.street_address,
          building_number: "1-1",
          building_number_kana: "1-1",
          street_address_kanji: "文京区千駄木3丁目",
          street_address_kana: "ブンキョウクセンダギ3チョウメ",
          city: "",
          city_kana: "",
          state: "東京都",
          zip_code: "1130022",
          country: "JP",
          dob_month: japan_compliance_info.birthday.month.to_s,
          dob_day: japan_compliance_info.birthday.day.to_s,
          dob_year: japan_compliance_info.birthday.year.to_s,
          phone: "+81312345678",
        )

        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_user).process

        expect(result[:success]).to be true
        expect(japan_user.reload.alive_user_compliance_info.phone).to eq("+81312345678")
      end

      it "accepts an address submission without city params when the record already has a city" do
        _result, with_city = japan_compliance_info.dup_and_save! do |n|
          n.city = "文京区"
          n.city_kana = "ブンキョウク"
          n.skip_stripe_job_on_create = true
        end
        expect(with_city.city).to eq("文京区")

        params = ActionController::Parameters.new(
          street_address_kanji: "千駄木4丁目",
          street_address_kana: "センダギ4チョウメ",
        )

        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_user).process

        expect(result[:success]).to be true
        expect(japan_user.reload.alive_user_compliance_info.street_address_kanji).to eq("千駄木4丁目")
      end
    end

    context "with a Japanese business account" do
      let(:japan_business_user) { create(:user) }
      let!(:japan_business_compliance_info) do
        create(
          :user_compliance_info,
          user: japan_business_user,
          country: "Japan",
          city: "文京区",
          state: "東京都",
          zip_code: "1130022",
          is_business: true,
          business_name: "Buy More KK",
          business_country: "Japan",
          business_city: nil,
          business_state: "東京都",
          business_zip_code: "1130022",
          business_type: UserComplianceInfo::BusinessTypes::LLC,
          business_tax_id: "0000000000000",
          json_data: {
            city_kana: "ブンキョウク",
            street_address_kanji: "千駄木3丁目",
            street_address_kana: "センダギ3チョウメ",
          }
        )
      end

      it "rejects a business address submission without a business city" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_street_address_kanji: "千代田区丸の内1丁目",
          business_street_address_kana: "チヨダクマルノウチ1チョウメ",
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_business_user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Business city/Ward is required for Japanese addresses. Please re-enter your business address including the city/ward.")
      end

      it "rejects a business postal-code-only update on a record with no business city" do
        # Same reasoning as the individual case: a postal code (or prefecture) change alone
        # still re-syncs the business address to Stripe, so the business city pair must be
        # present before it goes through.
        params = ActionController::Parameters.new(
          is_business: true,
          business_zip_code: "1000005",
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_business_user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Business city/Ward is required for Japanese addresses. Please re-enter your business address including the city/ward.")
      end

      it "accepts a business address submission that includes the business city fields" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_street_address_kanji: "丸の内1丁目",
          business_street_address_kana: "マルノウチ1チョウメ",
          business_city: "千代田区",
          business_city_kana: "チヨダク",
        )

        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_business_user).process

        expect(result[:success]).to be true
        new_compliance_info = japan_business_user.reload.alive_user_compliance_info
        expect(new_compliance_info.business_city).to eq("千代田区")
        expect(new_compliance_info.business_city_kana).to eq("チヨダク")
      end

      it "accepts a business address submission without business city params when the record already has a business city" do
        _result, with_business_city = japan_business_compliance_info.dup_and_save! do |n|
          n.business_city = "千代田区"
          n.business_city_kana = "チヨダク"
          n.skip_stripe_job_on_create = true
        end
        expect(with_business_city.business_city).to eq("千代田区")

        params = ActionController::Parameters.new(
          is_business: true,
          business_street_address_kanji: "丸の内2丁目",
          business_street_address_kana: "マルノウチ2チョウメ",
        )

        allow(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user: japan_business_user).process

        expect(result[:success]).to be true
        expect(japan_business_user.reload.alive_user_compliance_info.business_street_address_kanji).to eq("丸の内2丁目")
      end
    end

    context "with a US business that already has a 9-digit business_tax_id saved" do
      let(:us_business_user) do
        create(:user).tap { |u| create(:user_compliance_info_business, user: u) }
      end

      it "accepts a non-tax-id field update without re-submitting business_tax_id" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_street_address: "456 Updated Street",
        )

        result = described_class.new(compliance_params: params, user: us_business_user).process

        expect(result[:success]).to be true
        expect(us_business_user.alive_user_compliance_info.business_street_address).to eq("456 Updated Street")
      end

      it "rejects a too-short business_tax_id submitted in the same request" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "12345",
        )

        result = described_class.new(compliance_params: params, user: us_business_user).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("US business tax IDs (EIN) must have 9 digits.")
      end

      it "accepts a 9-digit business_tax_id submitted with formatting" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "12-3456789",
        )

        result = described_class.new(compliance_params: params, user: us_business_user).process

        expect(result[:success]).to be true
      end

      it "ignores a masked business_tax_id resubmission (containing bullet characters)" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_street_address: "456 Updated Street",
          business_tax_id: "\u2022\u2022-\u2022\u2022\u2022\u20221234",
        )

        result = described_class.new(compliance_params: params, user: us_business_user).process

        expect(result[:success]).to be true
        expect(us_business_user.alive_user_compliance_info.business_street_address).to eq("456 Updated Street")
      end

      it "ignores a masked individual_tax_id resubmission (containing asterisks)" do
        params = ActionController::Parameters.new(
          is_business: true,
          business_street_address: "456 Updated Street",
          individual_tax_id: "***-**-1234",
        )

        result = described_class.new(compliance_params: params, user: us_business_user).process

        expect(result[:success]).to be true
      end
    end

    context "with a Peru individual" do
      def create_peru_individual_user(individual_tax_id:)
        create(:user).tap do |u|
          create(
            :user_compliance_info,
            user: u,
            country: "Peru",
            state: nil,
            city: "Lima",
            zip_code: "15074",
            individual_tax_id:,
          )
        end
      end

      it "rejects a bare 8-digit DNI submitted without the verification digit" do
        user = create_peru_individual_user(individual_tax_id: "12345678-9")
        original = user.alive_user_compliance_info

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "12349316",
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = nil
        expect do
          result = described_class.new(compliance_params: params, user:).process
        end.not_to change { UserComplianceInfo.count }

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Your Peru DNI must include the verification digit (for example, 12345678-9).")
        expect(user.reload.alive_user_compliance_info.id).to eq(original.id)
      end

      it "rejects a DNI longer than 9 digits" do
        user = create_peru_individual_user(individual_tax_id: "12345678-9")

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "1234567890",
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Your Peru DNI must include the verification digit (for example, 12345678-9).")
      end

      it "accepts the DNI with its verification digit and a dash" do
        user = create_peru_individual_user(individual_tax_id: "00000000-0")

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "12345678-9",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.individual_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("12345678-9")
      end

      it "accepts the DNI with its verification digit and no dash" do
        user = create_peru_individual_user(individual_tax_id: "00000000-0")

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "123456789",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
      end

      it "rejects a representative's bare 8-digit DNI for a Peru business" do
        user = create(:user).tap do |u|
          create(
            :user_compliance_info_business,
            user: u,
            country: "Peru",
            business_country: "Peru",
            business_type: UserComplianceInfo::BusinessTypes::CORPORATION,
            individual_tax_id: "12345678-9",
          )
        end

        params = ActionController::Parameters.new(
          is_business: true,
          individual_tax_id: "12349316",
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Your Peru DNI must include the verification digit (for example, 12345678-9).")
      end

      it "accepts a representative's 9-digit DNI for a Peru business" do
        user = create(:user).tap do |u|
          create(
            :user_compliance_info_business,
            user: u,
            country: "Peru",
            business_country: "Peru",
            business_type: UserComplianceInfo::BusinessTypes::CORPORATION,
            individual_tax_id: "00000000-0",
          )
        end

        params = ActionController::Parameters.new(
          is_business: true,
          individual_tax_id: "12345678-9",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
      end
    end

    context "with a Singapore individual" do
      def create_singapore_individual_user(individual_tax_id:)
        create(:user).tap do |u|
          create(
            :user_compliance_info,
            user: u,
            country: "Singapore",
            state: nil,
            city: "Singapore",
            zip_code: "018956",
            individual_tax_id:,
          )
        end
      end

      it "rejects an NRIC missing its leading letter" do
        user = create_singapore_individual_user(individual_tax_id: "S1234567A")
        original = user.alive_user_compliance_info

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "1234567A",
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = nil
        expect do
          result = described_class.new(compliance_params: params, user:).process
        end.not_to change { UserComplianceInfo.count }

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Your NRIC/FIN must start with S, T, F, G or M and end with a letter (for example, S1234567A). Please enter it exactly as it appears on your ID.")
        expect(user.reload.alive_user_compliance_info.id).to eq(original.id)
      end

      it "rejects an NRIC that is only digits" do
        user = create_singapore_individual_user(individual_tax_id: "S1234567A")

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "123456789",
        )

        expect(StripeMerchantAccountManager).not_to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("Your NRIC/FIN must start with S, T, F, G or M and end with a letter (for example, S1234567A). Please enter it exactly as it appears on your ID.")
      end

      it "accepts a well-formed NRIC and stores it exactly as entered" do
        user = create_singapore_individual_user(individual_tax_id: "S0000000A")

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "T7654321B",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.individual_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("T7654321B")
      end

      it "accepts a lowercase FIN" do
        user = create_singapore_individual_user(individual_tax_id: "S0000000A")

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "g1234567x",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
      end

      it "tolerates spaces and dashes when checking the shape" do
        user = create_singapore_individual_user(individual_tax_id: "S0000000A")

        # Includes a non-breaking space (common when the ID is copied from a PDF
        # or website) alongside a regular space and a dash.
        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "S 1234567-\u00A0A",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
      end

      it "ignores a masked NRIC resubmission while saving other edited fields" do
        user = create_singapore_individual_user(individual_tax_id: "S1234567A")

        # The city differs from the stored record so the save path actually runs —
        # otherwise the service early-returns "nothing changed" before the NRIC
        # guard executes and this spec would pass even if the masked-value filter
        # were removed.
        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "•••••567A",
          city: "Bukit Timah",
        )

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        expect(user.reload.alive_user_compliance_info.city).to eq("Bukit Timah")
      end
    end

    context "with a non-US business" do
      def create_ie_business_user(business_tax_id:)
        create(:user).tap do |u|
          create(
            :user_compliance_info_business,
            user: u,
            country: "Ireland",
            business_country: "Ireland",
            business_state: "D",
            business_city: "Dublin",
            business_zip_code: "D02 XE80",
            business_type: UserComplianceInfo::BusinessTypes::CORPORATION,
            business_tax_id:,
          )
        end
      end

      it "preserves trailing letters in an Irish business_tax_id" do
        user = create_ie_business_user(business_tax_id: "000000000")

        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "3490731JH",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info) do |new_compliance_info|
          stored = new_compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
          expect(stored).to eq("3490731JH")
        end

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("3490731JH")
      end

      it "detects re-adding trailing letters as a change after the bug previously stripped them" do
        user = create_ie_business_user(business_tax_id: "3490731")

        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "3490731JH",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = nil
        expect do
          result = described_class.new(compliance_params: params, user:).process
        end.to change { UserComplianceInfo.count }.by(1)

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("3490731JH")
      end

      it "strips internal and surrounding whitespace but preserves alphanumeric characters" do
        user = create_ie_business_user(business_tax_id: "000000000")

        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "  3490731 JH  ",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("3490731JH")
      end

      it "strips Unicode whitespace such as U+202F narrow no-break space" do
        user = create_ie_business_user(business_tax_id: "000000000")

        # macOS in French locale inserts U+202F as a thousands separator, so a SIREN
        # pasted from a document arrives as "912 904 331" with invisible narrow
        # no-break spaces between the digit groups.
        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "912\u202F904\u202F331",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("912904331")
      end

      it "strips Unicode whitespace from a submitted individual_tax_id" do
        user = create(:user).tap do |u|
          create(
            :user_compliance_info,
            user: u,
            country: "France",
            individual_tax_id: "0000000000000",
          )
        end

        params = ActionController::Parameters.new(
          is_business: false,
          individual_tax_id: "12\u00A034\u202F56\u200989",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.individual_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("12345689")
      end

      it "collapses internal whitespace in a UK UTR-style business_tax_id" do
        user = create(:user).tap do |u|
          create(
            :user_compliance_info_business,
            user: u,
            country: "United Kingdom",
            business_country: "United Kingdom",
            business_state: "London",
            business_city: "London",
            business_zip_code: "SW1A 1AA",
            business_type: UserComplianceInfo::BusinessTypes::CORPORATION,
            business_tax_id: "0000000000",
          )
        end

        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "1234 5678 90",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("1234567890")
      end

      it "collapses dashes in a non-US business_tax_id" do
        user = create_ie_business_user(business_tax_id: "000000000")

        params = ActionController::Parameters.new(
          is_business: true,
          business_tax_id: "3490-731-JH",
        )

        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info)

        result = described_class.new(compliance_params: params, user:).process

        expect(result[:success]).to be true
        stored = user.reload.alive_user_compliance_info.business_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        expect(stored).to eq("3490731JH")
      end
    end
  end
end
