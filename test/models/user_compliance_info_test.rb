# frozen_string_literal: true

require "test_helper"

class UserComplianceInfoTest < ActiveSupport::TestCase
  self.described_class = UserComplianceInfo



  context_ UserComplianceInfo do
  context_ "encrypted" do
  context_ "individual_tax_id" do
        let(:user_compliance_info) { create(:user_compliance_info, individual_tax_id: "123456789") }

  test "is encrypted" do
          expect(user_compliance_info.individual_tax_id).to be_a(Strongbox::Lock)
          expect(user_compliance_info.individual_tax_id.decrypt("1234")).to eq("123456789")
        end

  test "outputs '*encrypted*' if no password given to decrypt" do
          expect(user_compliance_info.individual_tax_id.decrypt(nil)).to eq("*encrypted*")
        end
      end
    end

  context_ "has_completed_compliance_info?" do
  context_ "individual" do
  context_ "all fields completed" do
          let(:user_compliance_info) { create(:user_compliance_info) }

  test "returns true" do
            expect(user_compliance_info.has_completed_compliance_info?).to eq(true)
          end
        end

  context_ "some fields completed" do
          let(:user_compliance_info) { create(:user_compliance_info_empty, first_name: "First Name") }

  test "returns false" do
            expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
          end
        end

  context_ "all fields but individual tax id completed" do
          let(:user_compliance_info) { create(:user_compliance_info, individual_tax_id: nil) }

  test "returns false" do
            expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
          end
        end

  context_ "no fields completed" do
          let(:user_compliance_info) { create(:user_compliance_info_empty) }

  test "returns false" do
            expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
          end
        end
      end

  context_ "business" do
  context_ "all fields completed" do
          let(:user_compliance_info) { create(:user_compliance_info_business) }

  test "returns true" do
            expect(user_compliance_info.has_completed_compliance_info?).to eq(true)
          end
        end

  context_ "some fields completed" do
          let(:user_compliance_info) { create(:user_compliance_info_empty, is_business: true, business_name: "My Business") }

  test "returns false" do
            expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
          end
        end

  context_ "all fields but business tax id completed" do
          let(:user_compliance_info) { create(:user_compliance_info_business, business_tax_id: nil) }

  test "returns false" do
            expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
          end
        end

  context_ "no fields completed" do
          let(:user_compliance_info) { create(:user_compliance_info_empty, is_business: true) }

  test "returns false" do
            expect(user_compliance_info.has_completed_compliance_info?).to eq(false)
          end
        end
      end
    end

  context_ "legal entity fields" do
  context_ "legal_entity_country" do
  context_ "is an individual" do
          let(:user_compliance_info) { create(:user_compliance_info, country: "Canada") }

  test "returns the individual country" do
            expect(user_compliance_info.legal_entity_country).to eq("Canada")
          end
        end

  context_ "is a business" do
  context_ "has business_country set" do
            let(:user_compliance_info) { create(:user_compliance_info_business, country: "Canada", business_country: "United States") }

  test "returns the individual country" do
              expect(user_compliance_info.legal_entity_country).to eq("United States")
            end
          end

  context_ "does not have business_country set" do
            let(:user_compliance_info) { create(:user_compliance_info_business, country: "Canada", business_country: nil) }

  test "returns the individual country" do
              expect(user_compliance_info.legal_entity_country).to eq("Canada")
            end
          end
        end
      end

  context_ "legal_entity_country_code" do
  context_ "is an individual" do
          let(:user_compliance_info) { create(:user_compliance_info, country: "Canada") }

  test "returns the individual country" do
            expect(user_compliance_info.legal_entity_country_code).to eq("CA")
          end
        end

  context_ "is a business" do
  context_ "has business_country set" do
            let(:user_compliance_info) { create(:user_compliance_info_business, country: "Canada", business_country: "United States") }

  test "returns the individual country" do
              expect(user_compliance_info.legal_entity_country_code).to eq("US")
            end
          end

  context_ "does not have business_country set" do
            let(:user_compliance_info) { create(:user_compliance_info_business, country: "Canada", business_country: nil) }

  test "returns the individual country" do
              expect(user_compliance_info.legal_entity_country_code).to eq("CA")
            end
          end
        end
      end

  context_ "legal_entity_state_code" do
  context_ "is an individual" do
          let(:user_compliance_info) { create(:user_compliance_info, country: "Canada", state: "Ontario") }

  test "returns the individual state code" do
            expect(user_compliance_info.legal_entity_state_code).to eq("ON")
          end
        end

  context_ "is a business" do
          let(:user_compliance_info) do create(:user_compliance_info_business,
                                               country: "Canada",
                                               state: "Ontario",
                                               business_country: "United States",
                                               business_state: "New York") end

  test "returns the business state code" do
            expect(user_compliance_info.legal_entity_state_code).to eq("NY")
          end
        end
      end
    end

  context_ "legal_entity_payable_business_type" do
  context_ "individual" do
        let(:user_compliance_info) { create(:user_compliance_info) }

  test "returns INDIVIDUAL type" do
          expect(user_compliance_info.legal_entity_payable_business_type).to eq("INDIVIDUAL")
        end
      end

  context_ "llc" do
        let(:user_compliance_info) { create(:user_compliance_info_business) }

  test "returns LLC_PARTNER type" do
          expect(user_compliance_info.legal_entity_payable_business_type).to eq("LLC_PARTNER")
        end
      end

  context_ "corporation" do
        let(:user_compliance_info) { create(:user_compliance_info_business, business_type: UserComplianceInfo::BusinessTypes::CORPORATION) }

  test "returns CORPORATION type" do
          expect(user_compliance_info.legal_entity_payable_business_type).to eq("CORPORATION")
        end
      end
    end

  context_ "#first_and_last_name" do
      let(:user_compliance_info) { create(:user_compliance_info, first_name: " Alice ", last_name: nil) }

  test "returns stripped first_name and last_name after converting to strings" do
        expect(user_compliance_info.first_and_last_name).to eq "Alice"
        user_compliance_info.last_name = " Smith "
        expect(user_compliance_info.first_and_last_name).to eq "Alice Smith"
      end
    end

  context_ "stripped_fields" do
      let(:user_compliance_info) { create(:user_compliance_info, first_name: " Alice ", last_name: " Bob ", business_name: " My Business ") }

  test "strips all fields" do
        expect(user_compliance_info.first_name).to eq "Alice"
        expect(user_compliance_info.last_name).to eq "Bob"
        expect(user_compliance_info.business_name).to eq "My Business"
      end

  test "doesn't strip fields for existing records because they are immutable" do
        user_compliance_info = build(:user_compliance_info, first_name: " Alice ")
        user_compliance_info.save!(validate: false)
        expect { user_compliance_info.mark_deleted! }.not_to raise_exception
        expect(user_compliance_info.first_name).to eq " Alice "
        expect(user_compliance_info.deleted_at).not_to be_nil
      end
    end

  context_ "#has_individual_tax_id?" do
  context_ "when individual_tax_id is present" do
        let(:user_compliance_info) { create(:user_compliance_info, individual_tax_id: "123456789") }

  test "returns true" do
          expect(user_compliance_info.has_individual_tax_id?).to eq(true)
        end
      end

  context_ "when individual_tax_id is nil" do
        let(:user_compliance_info) { create(:user_compliance_info, individual_tax_id: nil) }

  test "returns false" do
          expect(user_compliance_info.has_individual_tax_id?).to eq(false)
        end
      end
    end

  context_ "#has_business_tax_id?" do
  context_ "when business_tax_id is present" do
        let(:user_compliance_info) { create(:user_compliance_info_business, business_tax_id: "98-7654321") }

  test "returns true" do
          expect(user_compliance_info.has_business_tax_id?).to eq(true)
        end
      end

  context_ "when business_tax_id is nil" do
        let(:user_compliance_info) { create(:user_compliance_info_business, business_tax_id: nil) }

  test "returns false" do
          expect(user_compliance_info.has_business_tax_id?).to eq(false)
        end
      end
    end

  context_ "kana_fields_format" do
  context_ "for Japanese users" do
  context_ "name kana fields" do
  test "allows valid katakana" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "タナカ", last_name_kana: "サクラショウテン" })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end

  test "rejects full-width parenthesis in name kana" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { business_name_kana: "カ）サクラショウテン" })
            uci.valid?
            expect(uci.errors[:base]).to include("Business name (Kana) may only contain katakana, spaces, dashes, and dots")
          end

  test "rejects kanji in name kana" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "日本語" })
            uci.valid?
            expect(uci.errors[:base]).to include("First name (Kana) may only contain katakana, spaces, dashes, and dots")
          end

  test "rejects digits in name kana" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { last_name_kana: "カタカナ123" })
            uci.valid?
            expect(uci.errors[:base]).to include("Last name (Kana) may only contain katakana, spaces, dashes, and dots")
          end

  test "allows blank name kana fields" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "", last_name_kana: nil })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end

  test "allows prolonged vowel mark (ー U+30FC)" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "テイラー" })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end

  test "allows full-width space (U+3000)" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "ジョン\u3000トレッゲサー" })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end

  test "allows half-width katakana (U+FF65-U+FF9F)" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { first_name_kana: "ｶﾀｶﾅ" })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end
        end

  context_ "address kana fields" do
  test "allows katakana with latin and digits" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { building_number_kana: "シブヤヒカリエ17F", street_address_kana: "チヨダ" })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end

  test "rejects kanji in address kana" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { street_address_kana: "渋谷区" })
            uci.valid?
            expect(uci.errors[:base]).to include("Street address (Kana) may only contain katakana, latin characters, digits, spaces, dashes, and dots")
          end

  test "rejects kanji in business address kana" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { business_building_number_kana: "渋谷", business_street_address_kana: "千代田区" })
            uci.valid?
            expect(uci.errors[:base]).to include("Business building number (Kana) may only contain katakana, latin characters, digits, spaces, dashes, and dots")
            expect(uci.errors[:base]).to include("Business street address (Kana) may only contain katakana, latin characters, digits, spaces, dashes, and dots")
          end

  test "allows blank address kana fields" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { building_number_kana: nil, street_address_kana: "" })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end

  test "allows full-width space in address kana" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { street_address_kana: "シブヤ\u3000ヒカリエ" })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end

  test "allows prolonged vowel mark in address kana" do
            uci = build(:user_compliance_info, country: "Japan", json_data: { street_address_kana: "シブヤヒカリエドオリー" })
            uci.valid?
            expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
          end
        end
      end

  context_ "for non-Japanese users" do
  test "skips kana validation entirely" do
          uci = build(:user_compliance_info, country: "United States", json_data: { first_name_kana: "invalid）data" })
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/Kana/))
        end
      end
    end

  context_ "street_address_kana_must_contain_katakana" do
  test "rejects Latin-only street_address_kana" do
        uci = build(:user_compliance_info, country: "Japan", json_data: { street_address_kana: "Shibuya" })
        uci.valid?
        expect(uci.errors[:base]).to include("Street address (Kana) must include katakana characters")
      end

  test "accepts street_address_kana with katakana" do
        uci = build(:user_compliance_info, country: "Japan", json_data: { street_address_kana: "シブヤ" })
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/must include katakana/))
      end

  test "accepts street_address_kana with mixed katakana and Latin" do
        uci = build(:user_compliance_info, country: "Japan", json_data: { street_address_kana: "シブヤ1-2-3" })
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/must include katakana/))
      end

  test "does not apply to building_number_kana" do
        uci = build(:user_compliance_info, country: "Japan", json_data: { building_number_kana: "123" })
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/must include katakana/))
      end

  test "rejects Latin-only business_street_address_kana" do
        uci = build(:user_compliance_info, country: "Japan", json_data: { business_street_address_kana: "Chiyoda" })
        uci.valid?
        expect(uci.errors[:base]).to include("Business street address (Kana) must include katakana characters")
      end

  test "accepts business_street_address_kana with katakana" do
        uci = build(:user_compliance_info, country: "Japan", json_data: { business_street_address_kana: "チヨダ" })
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/must include katakana/))
      end

  test "accepts business_street_address_kana with mixed katakana and Latin" do
        uci = build(:user_compliance_info, country: "Japan", json_data: { business_street_address_kana: "チヨダ1-2" })
        uci.valid?
        expect(uci.errors[:base]).not_to include(a_string_matching(/must include katakana/))
      end
    end

  context_ "business_name_romaji_format" do
  context_ "for Japanese business accounts" do
  test "allows latin business name" do
          uci = build(:user_compliance_info_business, country: "Japan", business_country: "Japan", business_name: "Sakura Shoten Co., Ltd.")
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/romaji/))
        end

  test "rejects Japanese characters in business name" do
          uci = build(:user_compliance_info_business, country: "Japan", business_country: "Japan", business_name: "カ）サクラショウテン")
          uci.valid?
          expect(uci.errors[:base]).to include("Legal business name must be in romaji (latin characters) for Japanese accounts")
        end

  test "skips validation for individual (non-business) accounts" do
          uci = build(:user_compliance_info, country: "Japan", business_name: "カ）サクラショウテン")
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/romaji/))
        end

  test "skips validation when business name is blank" do
          uci = build(:user_compliance_info_business, country: "Japan", business_country: "Japan", business_name: "")
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/romaji/))
        end
      end

  context_ "for non-Japanese business accounts" do
  test "skips romaji validation" do
          uci = build(:user_compliance_info_business, country: "United States", business_name: "カ）サクラショウテン")
          uci.valid?
          expect(uci.errors[:base]).not_to include(a_string_matching(/romaji/))
        end
      end
    end
  end
end
