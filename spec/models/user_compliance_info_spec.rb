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
end
