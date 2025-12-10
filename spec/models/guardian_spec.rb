# frozen_string_literal: true

require "spec_helper"

describe Guardian do
  describe "associations" do
    it "belongs to user" do
      guardian = create(:guardian)
      expect(guardian.user).to be_a(User)
    end

    it "enforces uniqueness per user" do
      user = create(:user)
      create(:guardian, user: user)

      expect { create(:guardian, user: user) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "validations" do
    let(:user) { create(:user) }

    describe "guardian_must_be_at_least_18" do
      it "is valid when guardian is 18 or older" do
        guardian = build(:guardian, user: user, date_of_birth: 18.years.ago.to_date)
        expect(guardian).to be_valid
      end

      it "is invalid when guardian is under 18" do
        guardian = build(:guardian, user: user, date_of_birth: 17.years.ago.to_date)
        expect(guardian).not_to be_valid
        expect(guardian.errors[:base]).to include("Guardian must be at least 18 years old")
      end

      it "allows nil date_of_birth" do
        guardian = build(:guardian, user: user, date_of_birth: nil)
        expect(guardian).to be_valid
      end
    end
  end

  describe "encrypted individual_tax_id" do
    let(:guardian) { create(:guardian, individual_tax_id: "123456789") }

    it "encrypts the tax ID" do
      expect(guardian.individual_tax_id).to be_a(Strongbox::Lock)
      expect(guardian.individual_tax_id.decrypt("1234")).to eq("123456789")
    end

    it "returns '*encrypted*' if no password given" do
      expect(guardian.individual_tax_id.decrypt(nil)).to eq("*encrypted*")
    end
  end

  describe "#birthday" do
    it "returns date_of_birth" do
      guardian = create(:guardian, date_of_birth: Date.new(1980, 5, 15))
      expect(guardian.birthday).to eq(Date.new(1980, 5, 15))
    end
  end

  describe "#full_name" do
    it "returns first and last name combined" do
      guardian = create(:guardian, first_name: "John", last_name: "Doe")
      expect(guardian.full_name).to eq("John Doe")
    end

    it "handles nil values" do
      guardian = create(:guardian, first_name: nil, last_name: "Doe")
      expect(guardian.full_name).to eq("Doe")
    end
  end

  describe "#has_completed_info?" do
    let(:user) { create(:user) }

    it "returns true when all required fields are present" do
      guardian = create(:guardian)
      expect(guardian.has_completed_info?).to be(true)
    end

    it "returns false when first_name is missing" do
      guardian = build(:guardian, user: user, first_name: nil)
      expect(guardian.has_completed_info?).to be(false)
    end

    it "returns false when last_name is missing" do
      guardian = build(:guardian, user: user, last_name: nil)
      expect(guardian.has_completed_info?).to be(false)
    end

    it "returns false when date_of_birth is missing" do
      guardian = build(:guardian, user: user, date_of_birth: nil)
      expect(guardian.has_completed_info?).to be(false)
    end

    it "returns false when street_address is missing" do
      guardian = build(:guardian, user: user, street_address: nil)
      expect(guardian.has_completed_info?).to be(false)
    end

    it "returns false when city is missing" do
      guardian = build(:guardian, user: user, city: nil)
      expect(guardian.has_completed_info?).to be(false)
    end

    it "returns false when state is missing" do
      guardian = build(:guardian, user: user, state: nil)
      expect(guardian.has_completed_info?).to be(false)
    end

    it "returns false when zip_code is missing" do
      guardian = build(:guardian, user: user, zip_code: nil)
      expect(guardian.has_completed_info?).to be(false)
    end

    it "returns false when country is missing" do
      guardian = build(:guardian, user: user, country: nil)
      expect(guardian.has_completed_info?).to be(false)
    end
  end

  describe "#has_individual_tax_id?" do
    it "returns true when tax ID is present" do
      guardian = create(:guardian, individual_tax_id: "123456789")
      expect(guardian.has_individual_tax_id?).to be(true)
    end

    it "returns false when tax ID is nil" do
      guardian = create(:guardian, individual_tax_id: nil)
      expect(guardian.has_individual_tax_id?).to be(false)
    end
  end

  describe "country code setting" do
    it "sets country_code from country name on save" do
      guardian = create(:guardian, country: "United States")
      expect(guardian.country_code).to eq("US")
    end

    it "sets country_code for Canada" do
      guardian = create(:guardian, country: "Canada")
      expect(guardian.country_code).to eq("CA")
    end

    it "sets country_code for Japan" do
      guardian = create(:guardian, country: "Japan")
      expect(guardian.country_code).to eq("JP")
    end
  end

  describe "Stripe integration fields" do
    it "stores stripe_person_id" do
      guardian = create(:guardian, stripe_person_id: "person_abc123")
      expect(guardian.reload.stripe_person_id).to eq("person_abc123")
    end

    it "stores stripe_tos_accepted" do
      guardian = create(:guardian, stripe_tos_accepted: true)
      expect(guardian.stripe_tos_accepted).to be(true)
    end

    it "stores stripe_tos_ip" do
      guardian = create(:guardian, stripe_tos_ip: "192.168.1.1")
      expect(guardian.stripe_tos_ip).to eq("192.168.1.1")
    end

    it "stores stripe_identity_document_id" do
      guardian = create(:guardian, stripe_identity_document_id: "file_abc123")
      expect(guardian.stripe_identity_document_id).to eq("file_abc123")
    end
  end

  describe "country-specific fields" do
    context "Canada" do
      it "stores job_title" do
        guardian = create(:guardian_canada)
        expect(guardian.job_title).to eq("Director")
      end
    end

    context "Japan" do
      let(:guardian) { create(:guardian_japan) }

      it "stores kanji name fields" do
        expect(guardian.first_name_kanji).to eq("太郎")
        expect(guardian.last_name_kanji).to eq("山田")
      end

      it "stores kana name fields" do
        expect(guardian.first_name_kana).to eq("タロウ")
        expect(guardian.last_name_kana).to eq("ヤマダ")
      end

      it "stores Japanese address fields" do
        expect(guardian.building_number).to eq("101")
        expect(guardian.street_address_kanji).to eq("東京都千代田区")
        expect(guardian.street_address_kana).to eq("トウキョウトチヨダク")
      end
    end

    context "UAE" do
      it "stores nationality" do
        guardian = create(:guardian_uae)
        expect(guardian.nationality).to eq("US")
      end
    end
  end

  describe "User association" do
    it "can access guardian through user" do
      user = create(:user)
      guardian = create(:guardian, user: user)

      expect(user.guardian).to eq(guardian)
    end

    it "destroys guardian when user is destroyed" do
      user = create(:user)
      guardian = create(:guardian, user: user)
      guardian_id = guardian.id

      user.destroy

      expect(Guardian.find_by(id: guardian_id)).to be_nil
    end
  end
end
