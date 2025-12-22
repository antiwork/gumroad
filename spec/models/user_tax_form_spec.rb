# frozen_string_literal: true

require "spec_helper"

RSpec.describe UserTaxForm do
  subject(:user_tax_form) { build(:user_tax_form) }

  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:tax_year) }
    it { is_expected.to validate_numericality_of(:tax_year).only_integer.is_greater_than_or_equal_to(UserTaxForm::MIN_TAX_YEAR) }
    it { is_expected.to validate_presence_of(:tax_form_type) }
    it { is_expected.to validate_inclusion_of(:tax_form_type).in_array(UserTaxForm::TAX_FORM_TYPES) }

    describe "uniqueness" do
      subject(:user_tax_form) { create(:user_tax_form) }

      it { is_expected.to validate_uniqueness_of(:user_id).scoped_to(:tax_year, :tax_form_type) }
    end
  end

  describe "scopes" do
    describe ".for_year" do
      it "returns tax forms for the specified year" do
        user = create(:user)
        create(:user_tax_form, user:, tax_year: 2022)
        tax_form_2023 = create(:user_tax_form, user:, tax_year: 2023)

        expect(described_class.for_year(2023)).to contain_exactly(tax_form_2023)
      end
    end
  end
end
