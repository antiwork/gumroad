# frozen_string_literal: true

class Guardian < ApplicationRecord
  include Strongbox

  belongs_to :user

  encrypt_with_public_key :individual_tax_id,
                          symmetric: :never,
                          public_key: OpenSSL::PKey.read(GlobalConfig.get("STRONGBOX_GENERAL"),
                                                         GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).public_key,
                          private_key: GlobalConfig.get("STRONGBOX_GENERAL")

  validates :user_id, presence: true, uniqueness: true
  validate :guardian_must_be_at_least_18, if: -> { date_of_birth.present? }

  before_save :set_country_code, if: -> { country.present? && country_changed? }

  def birthday
    date_of_birth
  end

  def full_name
    "#{first_name} #{last_name}".strip
  end

  def has_completed_info?
    first_name.present? &&
      last_name.present? &&
      date_of_birth.present? &&
      street_address.present? &&
      city.present? &&
      state.present? &&
      zip_code.present? &&
      country.present?
  end

  def has_individual_tax_id?
    individual_tax_id.present? && individual_tax_id.to_s != ""
  end

  private
    def guardian_must_be_at_least_18
      if date_of_birth > 18.years.ago.to_date
        errors.add(:base, "Guardian must be at least 18 years old")
      end
    end

    def set_country_code
      self.country_code = Compliance::Countries.find_by_name(country)&.alpha2
    end
end
