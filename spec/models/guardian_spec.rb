# frozen_string_literal: true

require "spec_helper"

describe Guardian do
  describe "validations" do
    it "is valid with the factory's attributes" do
      expect(build(:guardian)).to be_valid
    end

    it "requires the seller it belongs to, which is the boundary erasure is scoped by" do
      expect(build(:guardian, user: nil)).not_to be_valid
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

    %i[first_name last_name email date_of_birth street_address city zip_code country individual_tax_id].each do |field|
      it "is false without #{field}" do
        expect(build(:guardian, field => nil).has_completed_info?).to be(false)
      end
    end

    # Both directions of the country gate: Stripe wants a state where it has a subdivision list and
    # rejects one elsewhere, so requiring it unconditionally would strand a German guardian's minor.
    it "is false without state in a country whose addresses carry one" do
      expect(build(:guardian, country: "United States", state: nil).has_completed_info?).to be(false)
    end

    it "is true without state in a country whose addresses do not carry one" do
      expect(build(:guardian, country: "Germany", state: nil).has_completed_info?).to be(true)
    end

    it "is false until the guardian accepts the terms, because our payment partner requires their acceptance rather than the minor's" do
      expect(build(:guardian, stripe_tos_accepted: false).has_completed_info?).to be(false)
    end

    it "is false once the guardian is removed, since nothing clears the reference to them" do
      guardian = create(:guardian)

      guardian.mark_deleted!

      expect(guardian.has_completed_info?).to be(false)
    end
  end

  describe "#anonymize!" do
    let(:guardian) { create(:guardian) }

    it "clears the guardian's own identifying details" do
      guardian.anonymize!

      expect(guardian.reload).to have_attributes(
        first_name: nil,
        last_name: nil,
        email: nil,
        phone: nil,
        date_of_birth: nil,
        street_address: nil,
        city: nil,
        state: nil,
        zip_code: nil,
        country: nil,
        country_code: nil,
        nationality: nil,
        stripe_tos_ip: nil
      )
      # Strongbox always hands back a Lock, so ask the predicate rather than comparing to nil.
      expect(guardian.has_individual_tax_id?).to be(false)
    end

    # Erasure is a column-for-column obligation, so a column added to this table later must be
    # classified rather than quietly surviving. This fails on the migration that adds one, whether or
    # not the new column happens to be populated in any example.
    it "classifies every column as erased or retained" do
      expect(Guardian::ERASED_ON_ANONYMIZE + Guardian::RETAINED_ON_ANONYMIZE + ["updated_at"])
        .to match_array(Guardian.column_names)
    end

    it "nulls every column it classifies as erased" do
      guardian = create(:guardian, nationality: "US", stripe_tos_ip: "1.2.3.4")
      Guardian::ERASED_ON_ANONYMIZE.each { |column| expect(guardian[column]).to be_present }

      guardian.anonymize!

      guardian.reload
      # individual_tax_id is a Strongbox Lock rather than the raw column, so read it through the DB.
      erased = Guardian.where(id: guardian.id).pick(*Guardian::ERASED_ON_ANONYMIZE)
      expect(erased).to all(be_nil)
    end

    it "keeps the Stripe handle and the record that an adult accepted the terms" do
      guardian = create(:guardian, stripe_person_id: "person_1", stripe_tos_accepted_at: Time.current)

      guardian.anonymize!

      expect(guardian.reload).to have_attributes(
        stripe_person_id: "person_1",
        stripe_tos_accepted: true
      )
      expect(guardian.stripe_tos_accepted_at).to be_present
    end

    it "keeps the row so the compliance revisions referencing it stay intact" do
      user_compliance_info = create(:user_compliance_info, user: guardian.user, birthday: 15.years.ago.to_date, guardian:)

      guardian.anonymize!

      expect(Guardian.exists?(guardian.id)).to be(true)
      expect(user_compliance_info.reload.guardian_id).to eq(guardian.id)
    end

    it "leaves the record incomplete afterwards" do
      guardian.anonymize!

      expect(guardian.reload.has_completed_info?).to be(false)
    end
  end

  describe "destroying a guardian" do
    it "is refused while compliance revisions still reference it, rather than silently rewriting them" do
      guardian = create(:guardian)
      user_compliance_info = create(:user_compliance_info, user: guardian.user, birthday: 15.years.ago.to_date, guardian:)

      expect(guardian.destroy).to be(false)
      expect(user_compliance_info.reload.guardian_id).to eq(guardian.id)
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
