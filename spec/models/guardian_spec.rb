# frozen_string_literal: true

require "spec_helper"

describe Guardian do
  describe "validations" do
    it "is valid with the factory's attributes" do
      expect(build(:guardian)).to be_valid
    end

    it "rejects a guardian who is under 18" do
      guardian = build(:guardian, date_of_birth: 17.years.ago.to_date)

      expect(guardian).not_to be_valid
      expect(guardian.errors.full_messages).to include("The legal guardian must be at least 18 years old.")
    end

    it "accepts a guardian who turned 18 today" do
      expect(build(:guardian, date_of_birth: 18.years.ago.to_date)).to be_valid
    end

    it "rejects a malformed email" do
      expect(build(:guardian, email: "not-an-email")).not_to be_valid
    end

    it "allows a blank email, so a partially filled guardian can be saved as the seller types" do
      expect(build(:guardian, email: nil)).to be_valid
    end

    it "rejects a duplicate Stripe person id" do
      create(:guardian, stripe_person_id: "person_1")

      expect(build(:guardian, stripe_person_id: "person_1")).not_to be_valid
    end

    it "allows several guardians with no Stripe person id yet" do
      create(:guardian, stripe_person_id: nil)

      expect(build(:guardian, stripe_person_id: nil)).to be_valid
    end
  end

  describe "#country_code" do
    it "is derived from the country name" do
      expect(create(:guardian, country: "United States").country_code).to eq("US")
    end

    it "is updated when the country changes" do
      guardian = create(:guardian, country: "United States")

      guardian.update!(country: "Canada")

      expect(guardian.country_code).to eq("CA")
    end
  end

  describe "#full_name" do
    it "joins the names" do
      expect(build(:guardian, first_name: "Ellie", last_name: "Bartowski").full_name).to eq("Ellie Bartowski")
    end

    it "does not leave a stray space when one name is missing" do
      expect(build(:guardian, first_name: "Ellie", last_name: nil).full_name).to eq("Ellie")
    end
  end

  describe "#has_completed_info?" do
    it "is true when every field our payment partner asks for is present" do
      expect(build(:guardian)).to have_attributes(has_completed_info?: true)
    end

    %i[first_name last_name email date_of_birth street_address city zip_code country].each do |field|
      it "is false without #{field}" do
        expect(build(:guardian, field => nil).has_completed_info?).to be(false)
      end
    end

    it "is false until the guardian accepts the terms, because our payment partner requires their acceptance rather than the minor's" do
      expect(build(:guardian, stripe_tos_accepted: false).has_completed_info?).to be(false)
    end
  end

  describe "#has_individual_tax_id?" do
    it "is true when a tax id is stored" do
      expect(create(:guardian, individual_tax_id: "000000000").has_individual_tax_id?).to be(true)
    end

    it "is false when none is stored" do
      expect(create(:guardian, individual_tax_id: nil).has_individual_tax_id?).to be(false)
    end
  end

  describe "the stored tax id" do
    it "is encrypted at rest" do
      guardian = create(:guardian, individual_tax_id: "123456789")

      expect(guardian.reload.individual_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))).to eq("123456789")
      expect(Guardian.connection.select_value("SELECT individual_tax_id FROM guardians WHERE id = #{guardian.id}")).not_to include("123456789")
    end
  end

  describe "soft deletion" do
    it "keeps the record out of the alive scope" do
      guardian = create(:guardian)

      guardian.mark_deleted!

      expect(Guardian.alive).not_to include(guardian)
    end
  end
end
