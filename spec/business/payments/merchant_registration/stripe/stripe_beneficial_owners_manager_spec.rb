# frozen_string_literal: true

require "spec_helper"

describe StripeBeneficialOwnersManager do
  let(:user) { create(:user) }
  let(:stripe_account_id) { "acct_test_1234" }
  let(:merchant_account) do
    create(:merchant_account, user:, country: "GB", currency: "gbp",
                              charge_processor_merchant_id: stripe_account_id)
  end

  let(:representative_person) do
    Stripe::StripeObject.construct_from(
      id: "person_rep",
      first_name: "Justin",
      last_name: "Director",
      relationship: { representative: true, owner: true, director: true, percent_ownership: 33.33, title: "CEO" },
      address: { line1: "1 High St", city: "London", country: "GB", postal_code: "EC1" },
      dob: { day: 1, month: 1, year: 1980 },
      id_number_provided: true,
      ssn_last_4_provided: false,
      verification: { status: "verified" },
      requirements: { currently_due: [] }
    )
  end

  let(:other_owner_person) do
    Stripe::StripeObject.construct_from(
      id: "person_phil",
      first_name: "Phil",
      last_name: "Owner",
      relationship: { representative: false, owner: true, director: true, percent_ownership: 33.33, title: "Director" },
      address: { line1: "2 High St", city: "London", country: "GB", postal_code: "EC2" },
      dob: { day: 2, month: 2, year: 1981 },
      id_number_provided: true,
      ssn_last_4_provided: false,
      verification: { status: "verified" },
      requirements: { currently_due: [] }
    )
  end

  let(:third_owner_person) do
    Stripe::StripeObject.construct_from(
      id: "person_graham",
      first_name: "Graham",
      last_name: "Owner",
      relationship: { representative: false, owner: true, director: true, percent_ownership: 33.33, title: "Director" },
      address: { line1: "3 High St", city: "London", country: "GB", postal_code: "EC3" },
      dob: { day: 3, month: 3, year: 1982 },
      id_number_provided: false,
      ssn_last_4_provided: false,
      verification: { status: "unverified" },
      requirements: { currently_due: ["verification.document"] }
    )
  end

  before do
    create(:user_compliance_info_business, user:, business_country: "United Kingdom", country: "United Kingdom")
    merchant_account
  end

  describe ".eligible?" do
    it "returns true for a business user with a Gumroad-managed Stripe merchant account" do
      expect(described_class.eligible?(user)).to be true
    end

    it "returns false when the user has no Gumroad-managed Stripe account" do
      allow(user).to receive(:stripe_account).and_return(nil)
      expect(described_class.eligible?(user)).to be false
    end

    it "returns false when the seller is on a Stripe Connect OAuth account" do
      allow(merchant_account).to receive(:is_a_stripe_connect_account?).and_return(true)
      allow(user).to receive(:stripe_account).and_return(merchant_account)
      expect(described_class.eligible?(user)).to be false
    end

    it "returns false for an individual account" do
      individual_user = create(:user)
      create(:user_compliance_info, user: individual_user)
      create(:merchant_account, user: individual_user)
      expect(described_class.eligible?(individual_user)).to be false
    end
  end

  describe ".list" do
    it "returns every person on the account, including the representative, with relationship flags intact" do
      allow(Stripe::Account).to receive(:list_persons)
        .with(stripe_account_id, limit: described_class::PERSON_LIST_LIMIT)
        .and_return({ "data" => [representative_person, other_owner_person, third_owner_person] })

      result = described_class.list(user)

      expect(result.map { |o| o[:id] }).to eq(["person_rep", "person_phil", "person_graham"])
      expect(result.first[:relationship]).to include(representative: true, owner: true, director: true, percent_ownership: 33.33, title: "CEO")
      expect(result[1]).to include(
        first_name: "Phil",
        last_name: "Owner",
        relationship: include(owner: true, director: true, representative: false, percent_ownership: 33.33, title: "Director"),
        verification_status: "verified",
        requirements_currently_due: [],
      )
      expect(result.last[:requirements_currently_due]).to eq(["verification.document"])
    end

    it "returns the lone representative when no other owners exist" do
      allow(Stripe::Account).to receive(:list_persons).and_return({ "data" => [representative_person] })
      result = described_class.list(user)
      expect(result.length).to eq(1)
      expect(result.first[:relationship][:representative]).to be true
    end

    it "exposes nationality so the React form can pre-fill it when re-editing an owner" do
      person_with_nationality = Stripe::StripeObject.construct_from(
        id: "person_uae",
        first_name: "Hassan",
        last_name: "Al-Maktoum",
        relationship: { representative: false, owner: true, director: true },
        nationality: "AE",
      )
      allow(Stripe::Account).to receive(:list_persons).and_return({ "data" => [person_with_nationality] })
      expect(described_class.list(user).first[:nationality]).to eq("AE")
    end

    it "does not expose the raw id_number or ssn_last_4" do
      allow(Stripe::Account).to receive(:list_persons).and_return({ "data" => [other_owner_person] })
      result = described_class.list(user).first
      expect(result).not_to have_key(:id_number)
      expect(result).not_to have_key(:ssn_last_4)
      expect(result[:id_number_provided]).to be true
      expect(result[:ssn_last_4_provided]).to be false
    end

    it "raises NotEligibleError for ineligible users" do
      allow(user).to receive(:stripe_account).and_return(nil)
      expect { described_class.list(user) }.to raise_error(StripeBeneficialOwnersManager::NotEligibleError)
    end
  end

  describe ".create" do
    let(:params) do
      ActionController::Parameters.new(
        first_name: "Phil",
        last_name: "Owner",
        email: "phil@example.com",
        phone: "+447700900000",
        id_number: "AB123456C",
        title: "Director",
        owner: "true",
        director: "true",
        executive: "false",
        percent_ownership: "33.33",
        dob: { day: "2", month: "2", year: "1981" },
        address: { line1: "2 High St", city: "London", state: "Greater London", postal_code: "EC2", country: "GB" },
      ).permit!
    end

    it "creates a Stripe person with mapped relationship flags and no representative bit" do
      expect(Stripe::Account).to receive(:create_person) do |account_id, attrs|
        expect(account_id).to eq(stripe_account_id)
        expect(attrs[:first_name]).to eq("Phil")
        expect(attrs[:last_name]).to eq("Owner")
        expect(attrs[:email]).to eq("phil@example.com")
        expect(attrs[:id_number]).to eq("AB123456C")
        expect(attrs[:dob]).to eq(day: 2, month: 2, year: 1981)
        expect(attrs[:address]).to include(line1: "2 High St", city: "London", state: "Greater London", postal_code: "EC2", country: "GB")
        expect(attrs[:relationship]).to include(
          owner: true, director: true, executive: false,
          representative: false, title: "Director", percent_ownership: 33.33
        )
        other_owner_person
      end

      result = described_class.create(user, params)
      expect(result[:id]).to eq("person_phil")
    end

    it "lets a Stripe ownership-percent error propagate to the caller" do
      allow(Stripe::Account).to receive(:create_person)
        .and_raise(Stripe::InvalidRequestError.new("The total combined ownership of the company would exceed 100 percent.", "relationship[percent_ownership]"))
      expect { described_class.create(user, params) }.to raise_error(Stripe::InvalidRequestError, /exceed 100/)
    end

    it "raises NotEligibleError for ineligible users" do
      allow(user).to receive(:stripe_account).and_return(nil)
      expect { described_class.create(user, params) }.to raise_error(StripeBeneficialOwnersManager::NotEligibleError)
    end

    it "raises MissingRequiredFieldError when email or phone is missing" do
      blank_email = params.merge(email: "")
      expect { described_class.create(user, blank_email) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Email is required/)

      blank_phone = params.merge(phone: "  ")
      expect { described_class.create(user, blank_phone) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Phone is required/)

      blank_both = params.merge(email: "", phone: nil, first_name: "")
      expect { described_class.create(user, blank_both) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /First name, Email, and Phone are required/)
    end

    it "raises MissingRequiredFieldError when address sub-fields are missing" do
      blank_state = params.deep_dup
      blank_state[:address] = blank_state[:address].merge(country: "US", state: "")
      expect { described_class.create(user, blank_state) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /State or region is required/)

      no_address = params.except(:address)
      expect { described_class.create(user, no_address) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Street address, City, State or region, Postal code, and Country are required/)
    end

    it "does not require postal_code when the address country is Botswana (BW has no postal codes)" do
      bw_params = params.deep_dup
      bw_params[:address] = { line1: "Plot 50", city: "Gaborone", state: "South-East", country: "BW", postal_code: "" }
      allow(Stripe::Account).to receive(:create_person).and_return(other_owner_person)
      expect { described_class.create(user, bw_params) }.not_to raise_error
    end

    it "requires nationality when seller's compliance country is one of AE/SG/BD/PK" do
      user.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info_uae_business, user: user)
      missing_nationality = params.deep_dup
      missing_nationality[:nationality] = ""
      expect { described_class.create(user, missing_nationality) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Nationality is required/)
    end

    it "sends kanji/kana name + address_kanji + address_kana for JP business sellers" do
      user.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: user, country: "Japan", is_business: true,
                                    first_name_kanji: "太郎", last_name_kanji: "山田",
                                    first_name_kana: "タロウ", last_name_kana: "ヤマダ")
      jp_params = params.deep_dup
      jp_params[:first_name_kanji] = "太郎"
      jp_params[:last_name_kanji] = "山田"
      jp_params[:first_name_kana] = "タロウ"
      jp_params[:last_name_kana] = "ヤマダ"
      jp_params[:address] = {
        country: "JP", state: "東京都", postal_code: "100-0001",
        building_number: "1-1", building_number_kana: "1-1",
        street_address_kanji: "千代田", street_address_kana: "チヨダ",
      }
      expect(Stripe::Account).to receive(:create_person) do |_account_id, attrs|
        expect(attrs[:first_name_kanji]).to eq("太郎")
        expect(attrs[:last_name_kanji]).to eq("山田")
        expect(attrs[:first_name_kana]).to eq("タロウ")
        expect(attrs[:last_name_kana]).to eq("ヤマダ")
        expect(attrs[:address_kanji]).to include(line1: "1-1", town: "千代田", state: "東京都", country: "JP", postal_code: "100-0001")
        expect(attrs[:address_kana]).to include(line1: "1-1", town: "チヨダ", state: "トウキョウト", country: "JP")
        expect(attrs).not_to have_key(:address)
        other_owner_person
      end
      described_class.create(user, jp_params)
    end

    it "sends kanji/kana names with a Latin address when a JP seller adds a non-JP-resident BO" do
      user.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: user, country: "Japan", is_business: true,
                                    first_name_kanji: "太郎", last_name_kanji: "山田",
                                    first_name_kana: "タロウ", last_name_kana: "ヤマダ")
      jp_params = params.deep_dup
      jp_params[:first_name_kanji] = "太郎"
      jp_params[:last_name_kanji] = "山田"
      jp_params[:first_name_kana] = "タロウ"
      jp_params[:last_name_kana] = "ヤマダ"
      jp_params[:address] = {
        line1: "1 Market St", line2: "Suite 100", city: "San Francisco",
        state: "CA", postal_code: "94105", country: "US",
      }
      expect(Stripe::Account).to receive(:create_person) do |_account_id, attrs|
        expect(attrs[:first_name_kanji]).to eq("太郎")
        expect(attrs[:last_name_kanji]).to eq("山田")
        expect(attrs[:address]).to include(line1: "1 Market St", line2: "Suite 100", city: "San Francisco",
                                           state: "CA", postal_code: "94105", country: "US")
        expect(attrs).not_to have_key(:address_kanji)
        expect(attrs).not_to have_key(:address_kana)
        other_owner_person
      end
      described_class.create(user, jp_params)
    end

    it "sends full_name_aliases for SGP sellers (Singapore MAS rule — required on every Person)" do
      user.alive_user_compliance_info.mark_deleted!
      sg_compliance = create(:user_compliance_info_singapore, user: user)
      sg_compliance.dup_and_save! { |c| c.is_business = true }
      sg_params = params.deep_dup
      sg_params[:nationality] = "SG"
      expect(Stripe::Account).to receive(:create_person) do |_account_id, attrs|
        expect(attrs[:full_name_aliases]).to eq([""])
        other_owner_person
      end
      described_class.create(user, sg_params)
    end

    it "raises MissingRequiredFieldError when id_number is missing on create" do
      no_id = params.merge(id_number: "")
      expect { described_class.create(user, no_id) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Personal tax ID number is required/)
    end

    it "raises MissingRequiredFieldError when dob is missing entirely (API client bypassing the UI)" do
      no_dob = params.except(:dob)
      expect { described_class.create(user, no_dob) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Date of birth is required/)
    end

    it "raises MissingRequiredFieldError when one of day/month/year is blank" do
      partial_dob = params.deep_dup
      partial_dob[:dob][:day] = ""
      expect { described_class.create(user, partial_dob) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Date of birth is required/)
    end

    it "accepts a blank address.state for countries outside the curated state-list set (Singapore, mirroring the rep flow)" do
      user.alive_user_compliance_info.mark_deleted!
      sg_compliance = create(:user_compliance_info_singapore, user: user)
      sg_compliance.dup_and_save! { |c| c.is_business = true }
      sg_params = params.deep_dup
      sg_params[:nationality] = "SG"
      sg_params[:address] = sg_params[:address].merge(country: "SG", state: "")
      expect(Stripe::Account).to receive(:create_person).and_return(other_owner_person)
      described_class.create(user, sg_params)
    end

    it "raises MissingRequiredFieldError when owner=true but percent_ownership is blank" do
      bad = params.merge(owner: "true", percent_ownership: "")
      expect { described_class.create(user, bad) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Ownership percentage is required/)
    end

    it "allows owner=false with blank percent_ownership (director-only BO)" do
      ok = params.merge(owner: "false", director: "true", percent_ownership: "")
      expect(Stripe::Account).to receive(:create_person).and_return(other_owner_person)
      described_class.create(user, ok)
    end
  end

  describe ".update" do
    let(:params) do
      ActionController::Parameters.new(
        first_name: "Phil",
        last_name: "Owner",
        email: "phil@example.com",
        phone: "+447700900000",
        title: "Director",
        owner: "true",
        director: "true",
        executive: "false",
        percent_ownership: "34",
        dob: { day: "2", month: "2", year: "1981" },
      ).permit!
    end

    it "updates the person and never sets representative: true" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, "person_phil").and_return(other_owner_person)
      expect(Stripe::Account).to receive(:update_person) do |account_id, person_id, attrs|
        expect(account_id).to eq(stripe_account_id)
        expect(person_id).to eq("person_phil")
        expect(attrs[:relationship][:representative]).to be false
        expect(attrs[:relationship][:percent_ownership]).to eq(34.0)
        other_owner_person
      end

      described_class.update(user, "person_phil", params)
    end

    it "allows editing the representative's percent_ownership, title, and role flags only" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, "person_rep").and_return(representative_person)

      rep_params = ActionController::Parameters.new(
        first_name: "ShouldBeIgnored",
        last_name: "AlsoIgnored",
        title: "Founder",
        owner: "true",
        director: "true",
        executive: "false",
        percent_ownership: "50",
        dob: { day: "9", month: "9", year: "1999" },
        address: { line1: "Ignored", city: "Ignored", postal_code: "Ignored", country: "GB" },
      ).permit!

      expect(Stripe::Account).to receive(:update_person) do |account_id, person_id, attrs|
        expect(account_id).to eq(stripe_account_id)
        expect(person_id).to eq("person_rep")
        expect(attrs.keys).to eq([:relationship])
        expect(attrs[:relationship]).to include(
          representative: true, owner: true, director: true, executive: false,
          title: "Founder", percent_ownership: 50.0,
        )
        representative_person
      end

      described_class.update(user, "person_rep", rep_params)
    end

    it "omits id_number when the form value is blank, preserving Stripe's stored value" do
      allow(Stripe::Account).to receive(:retrieve_person).and_return(other_owner_person)
      blank_id_params = params.merge(id_number: "")
      expect(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attrs|
        expect(attrs).not_to have_key(:id_number)
        expect(attrs).not_to have_key(:ssn_last_4)
        other_owner_person
      end

      described_class.update(user, "person_phil", blank_id_params)
    end

    it "raises MissingRequiredFieldError when email or phone is missing on a non-rep update" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, "person_phil").and_return(other_owner_person)
      expect(Stripe::Account).not_to receive(:update_person)
      expect { described_class.update(user, "person_phil", params.merge(email: "")) }
        .to raise_error(StripeBeneficialOwnersManager::MissingRequiredFieldError, /Email is required/)
    end

    it "does not re-assert full_name_aliases on SGP non-rep updates so externally-set aliases are preserved" do
      user.alive_user_compliance_info.mark_deleted!
      sg_compliance = create(:user_compliance_info_singapore, user: user)
      sg_compliance.dup_and_save! { |c| c.is_business = true }
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, "person_phil").and_return(other_owner_person)
      sg_params = params.deep_dup
      sg_params[:nationality] = "SG"
      expect(Stripe::Account).to receive(:update_person) do |_account_id, _person_id, attrs|
        expect(attrs).not_to have_key(:full_name_aliases)
        other_owner_person
      end

      described_class.update(user, "person_phil", sg_params)
    end
  end

  describe ".destroy" do
    it "deletes the person and returns a confirmation hash" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, "person_phil").and_return(other_owner_person)
      expect(Stripe::Account).to receive(:delete_person).with(stripe_account_id, "person_phil")
      expect(described_class.destroy(user, "person_phil")).to eq(deleted: true, id: "person_phil")
    end

    it "refuses to delete the representative" do
      allow(Stripe::Account).to receive(:retrieve_person).with(stripe_account_id, "person_rep").and_return(representative_person)
      expect(Stripe::Account).not_to receive(:delete_person)
      expect { described_class.destroy(user, "person_rep") }
        .to raise_error(StripeBeneficialOwnersManager::RepresentativeNotEditableError)
    end
  end
end
