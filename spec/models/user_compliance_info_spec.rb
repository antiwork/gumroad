# frozen_string_literal: true

require "spec_helper"

describe UserComplianceInfo do
  describe "encrypted" do
    describe "individual_tax_id" do
      let(:user_compliance_info) { create(:user_compliance_info, individual_tax_id: "123456789") }

      it "is encrypted" do
        expect(user_compliance_info.individual_tax_id).to be_a(Strongbox::Lock)
        expect(user_compliance_info.individual_tax_id.decrypt("1234")).to eq("123456789")
      end

      it "outputs '*encrypted*' if no password given to decrypt" do
        expect(user_compliance_info.individual_tax_id.decrypt(nil)).to eq("*encrypted*")
      end
    end
  end

  describe "has_completed_compliance_info?" do
    describe "individual" do
      describe "all fields completed" do
        let(:user_compliance_info) { create(:user_compliance_info) }

        it "returns true" do
          expect(user_compliance_info.has_completed_compliance_info?).to eq(true)
        end
      end

      describe "some fields completed" do
        let(:user_compliance_info) { create(:user_compliance_info_empty, first_name: "First Name") }

        it "returns false" do
          expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
        end
      end

      describe "all fields but individual tax id completed" do
        let(:user_compliance_info) { create(:user_compliance_info, individual_tax_id: nil) }

        it "returns false" do
          expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
        end
      end

      describe "no fields completed" do
        let(:user_compliance_info) { create(:user_compliance_info_empty) }

        it "returns false" do
          expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
        end
      end
    end

    describe "business" do
      describe "all fields completed" do
        let(:user_compliance_info) { create(:user_compliance_info_business) }

        it "returns true" do
          expect(user_compliance_info.has_completed_compliance_info?).to eq(true)
        end
      end

      describe "some fields completed" do
        let(:user_compliance_info) { create(:user_compliance_info_empty, is_business: true, business_name: "My Business") }

        it "returns false" do
          expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
        end
      end

      describe "all fields but business tax id completed" do
        let(:user_compliance_info) { create(:user_compliance_info_business, business_tax_id: nil) }

        it "returns false" do
          expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
        end
      end

      describe "no fields completed" do
        let(:user_compliance_info) { create(:user_compliance_info_empty, is_business: true) }

        it "returns false" do
          expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
        end
      end
    end
  end

  describe "legal entity fields" do
    describe "legal_entity_country" do
      describe "is an individual" do
        let(:user_compliance_info) { create(:user_compliance_info, country: "Canada") }

        it "returns the individual country" do
          expect(user_compliance_info.legal_entity_country).to eq("Canada")
        end
      end

      describe "is a business" do
        describe "has business_country set" do
          let(:user_compliance_info) { create(:user_compliance_info_business, country: "Canada", business_country: "United States") }

          it "returns the individual country" do
            expect(user_compliance_info.legal_entity_country).to eq("United States")
          end
        end

        describe "does not have business_country set" do
          let(:user_compliance_info) { create(:user_compliance_info_business, country: "Canada", business_country: nil) }

          it "returns the individual country" do
            expect(user_compliance_info.legal_entity_country).to eq("Canada")
          end
        end
      end
    end

    describe "legal_entity_country_code" do
      describe "is an individual" do
        let(:user_compliance_info) { create(:user_compliance_info, country: "Canada") }

        it "returns the individual country" do
          expect(user_compliance_info.legal_entity_country_code).to eq("CA")
        end
      end

      describe "is a business" do
        describe "has business_country set" do
          let(:user_compliance_info) { create(:user_compliance_info_business, country: "Canada", business_country: "United States") }

          it "returns the individual country" do
            expect(user_compliance_info.legal_entity_country_code).to eq("US")
          end
        end

        describe "does not have business_country set" do
          let(:user_compliance_info) { create(:user_compliance_info_business, country: "Canada", business_country: nil) }

          it "returns the individual country" do
            expect(user_compliance_info.legal_entity_country_code).to eq("CA")
          end
        end
      end
    end

    describe "legal_entity_state_code" do
      describe "is an individual" do
        let(:user_compliance_info) { create(:user_compliance_info, country: "Canada", state: "Ontario") }

        it "returns the individual state code" do
          expect(user_compliance_info.legal_entity_state_code).to eq("ON")
        end
      end

      describe "is a business" do
        let(:user_compliance_info) do create(:user_compliance_info_business,
                                             country: "Canada",
                                             state: "Ontario",
                                             business_country: "United States",
                                             business_state: "New York") end

        it "returns the business state code" do
          expect(user_compliance_info.legal_entity_state_code).to eq("NY")
        end
      end
    end
  end

  describe "legal_entity_payable_business_type" do
    describe "individual" do
      let(:user_compliance_info) { create(:user_compliance_info) }

      it "returns INDIVIDUAL type" do
        expect(user_compliance_info.legal_entity_payable_business_type).to eq("INDIVIDUAL")
      end
    end

    describe "llc" do
      let(:user_compliance_info) { create(:user_compliance_info_business) }

      it "returns LLC_PARTNER type" do
        expect(user_compliance_info.legal_entity_payable_business_type).to eq("LLC_PARTNER")
      end
    end

    describe "corporation" do
      let(:user_compliance_info) { create(:user_compliance_info_business, business_type: UserComplianceInfo::BusinessTypes::CORPORATION) }

      it "returns CORPORATION type" do
        expect(user_compliance_info.legal_entity_payable_business_type).to eq("CORPORATION")
      end
    end
  end

  describe "#first_and_last_name" do
    let(:user_compliance_info) { create(:user_compliance_info, first_name: " Alice ", last_name: nil) }

    it "returns stripped first_name and last_name after converting to strings" do
      expect(user_compliance_info.first_and_last_name).to eq "Alice"
      user_compliance_info.last_name = " Smith "
      expect(user_compliance_info.first_and_last_name).to eq "Alice Smith"
    end
  end

  describe "stripped_fields" do
    let(:user_compliance_info) { create(:user_compliance_info, first_name: " Alice ", last_name: " Bob ", business_name: " My Business ") }

    it "strips all fields" do
      expect(user_compliance_info.first_name).to eq "Alice"
      expect(user_compliance_info.last_name).to eq "Bob"
      expect(user_compliance_info.business_name).to eq "My Business"
    end

    it "doesn't strip fields for existing records because they are immutable" do
      user_compliance_info = build(:user_compliance_info, first_name: " Alice ")
      user_compliance_info.save!(validate: false)
      expect { user_compliance_info.mark_deleted! }.not_to raise_exception
      expect(user_compliance_info.first_name).to eq " Alice "
      expect(user_compliance_info.deleted_at).to_not be_nil
    end
  end

  describe "#has_individual_tax_id?" do
    describe "when individual_tax_id is present" do
      let(:user_compliance_info) { create(:user_compliance_info, individual_tax_id: "123456789") }

      it "returns true" do
        expect(user_compliance_info.has_individual_tax_id?).to eq(true)
      end
    end

    describe "when individual_tax_id is nil" do
      let(:user_compliance_info) { create(:user_compliance_info, individual_tax_id: nil) }

      it "returns false" do
        expect(user_compliance_info.has_individual_tax_id?).to eq(false)
      end
    end
  end

  describe "#has_business_tax_id?" do
    describe "when business_tax_id is present" do
      let(:user_compliance_info) { create(:user_compliance_info_business, business_tax_id: "98-7654321") }

      it "returns true" do
        expect(user_compliance_info.has_business_tax_id?).to eq(true)
      end
    end

    describe "when business_tax_id is nil" do
      let(:user_compliance_info) { create(:user_compliance_info_business, business_tax_id: nil) }

      it "returns false" do
        expect(user_compliance_info.has_business_tax_id?).to eq(false)
      end
    end
  end

  describe "kana_fields_format" do
    describe "for Japanese users" do
      describe "name kana fields" do
        it "allows valid katakana" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "タナカ", last_name_kana: "サクラショウテン" })
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
        end

        it "rejects full-width parenthesis in name kana" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { business_name_kana: "カ）サクラショウテン" })
          uci.valid?
          expect(uci.errors[:base]).to include("Business name (Kana) may only contain katakana, spaces, dashes, and dots")
        end

        it "rejects kanji in name kana" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "日本語" })
          uci.valid?
          expect(uci.errors[:base]).to include("First name (Kana) may only contain katakana, spaces, dashes, and dots")
        end

        it "rejects digits in name kana" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { last_name_kana: "カタカナ123" })
          uci.valid?
          expect(uci.errors[:base]).to include("Last name (Kana) may only contain katakana, spaces, dashes, and dots")
        end

        it "allows blank name kana fields" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "", last_name_kana: nil })
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
        end
      end

      describe "address kana fields" do
        it "allows katakana with latin and digits" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { building_number_kana: "シブヤヒカリエ17F", street_address_kana: "チヨダ" })
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
        end

        it "rejects kanji in address kana" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { street_address_kana: "渋谷区" })
          uci.valid?
          expect(uci.errors[:base]).to include("Street address (Kana) may only contain katakana, latin characters, digits, spaces, dashes, and dots")
        end

        it "rejects kanji in business address kana" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { business_building_number_kana: "渋谷", business_street_address_kana: "千代田区" })
          uci.valid?
          expect(uci.errors[:base]).to include("Business building number (Kana) may only contain katakana, latin characters, digits, spaces, dashes, and dots")
          expect(uci.errors[:base]).to include("Business street address (Kana) may only contain katakana, latin characters, digits, spaces, dashes, and dots")
        end

        it "allows blank address kana fields" do
          uci = build(:user_compliance_info, country: "Japan", json_data: { building_number_kana: nil, street_address_kana: "" })
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
        end
      end
    end

    describe "for non-Japanese users" do
      it "skips kana validation entirely" do
        uci = build(:user_compliance_info, country: "United States", json_data: { first_name_kana: "invalid）data" })
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
      end
    end
  end

  describe "business_name_romaji_format" do
    describe "for Japanese business accounts" do
      it "allows latin business name" do
        uci = build(:user_compliance_info_business, country: "Japan", business_country: "Japan", business_name: "Sakura Shoten Co., Ltd.")
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/romaji/))
      end

      it "rejects Japanese characters in business name" do
        uci = build(:user_compliance_info_business, country: "Japan", business_country: "Japan", business_name: "カ）サクラショウテン")
        uci.valid?
        expect(uci.errors[:base]).to include("Legal business name must be in romaji (latin characters) for Japanese accounts")
      end

      it "skips validation for individual (non-business) accounts" do
        uci = build(:user_compliance_info, country: "Japan", business_name: "カ）サクラショウテン")
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/romaji/))
      end

      it "skips validation when business name is blank" do
        uci = build(:user_compliance_info_business, country: "Japan", business_country: "Japan", business_name: "")
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/romaji/))
      end
    end

    describe "for non-Japanese business accounts" do
      it "skips romaji validation" do
        uci = build(:user_compliance_info_business, country: "United States", business_name: "カ）サクラショウテン")
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/romaji/))
      end
    end
  end
end
