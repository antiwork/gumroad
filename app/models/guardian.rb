# frozen_string_literal: true

# The adult who takes legal responsibility for a seller who is under 18.
#
# Stripe will not verify a minor as the sole person on a payout account: when the account
# representative's date of birth says they are 13-17, Stripe raises a requirement for a second
# Person with relationship.legal_guardian set, and verifies that person instead. The minor stays
# the account holder, which is the whole point — the alternative is the parent owning the seller's
# Gumroad account outright.
#
# Mirrors UserComplianceInfo's split of responsibilities: validations here cover what must be true
# of any stored guardian, while has_completed_info? answers whether we have enough to hand Stripe.
# Unlike UserComplianceInfo this record is mutable, because it maps onto one Stripe Person that we
# update in place rather than a revision history.
class Guardian < ApplicationRecord
  include Deletable
  include Strongbox

  # Stripe's own floor for a person who can take responsibility for an account.
  MINIMUM_AGE = 18

  has_many :user_compliance_infos, dependent: :nullify

  encrypt_with_public_key :individual_tax_id,
                          symmetric: :never,
                          public_key: OpenSSL::PKey.read(GlobalConfig.get("STRONGBOX_GENERAL"),
                                                         GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).public_key,
                          private_key: GlobalConfig.get("STRONGBOX_GENERAL")

  stripped_fields :first_name, :last_name, :street_address, :city, :zip_code

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :stripe_person_id, uniqueness: true, allow_nil: true
  validate :guardian_is_an_adult

  before_validation :set_country_code, if: -> { country.present? && country_changed? }

  def full_name
    "#{first_name} #{last_name}".strip
  end

  # Whether we hold everything Stripe asks for about the guardian. Terms acceptance is part of it:
  # Stripe requires the guardian, not the minor, to accept them.
  def has_completed_info?
    first_name.present? &&
      last_name.present? &&
      email.present? &&
      date_of_birth.present? &&
      street_address.present? &&
      city.present? &&
      zip_code.present? &&
      country.present? &&
      stripe_tos_accepted?
  end

  def has_individual_tax_id?
    individual_tax_id.present?
  end
  alias_method :has_individual_tax_id, :has_individual_tax_id?

  private
    def guardian_is_an_adult
      return if date_of_birth.blank?
      return if date_of_birth <= MINIMUM_AGE.years.ago.to_date

      errors.add :base, "The legal guardian must be at least #{MINIMUM_AGE} years old."
    end

    def set_country_code
      self.country_code = Compliance::Countries.find_by_name(country)&.alpha2
    end
end
