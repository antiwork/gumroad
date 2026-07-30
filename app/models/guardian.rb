# frozen_string_literal: true

# The adult who takes legal responsibility for a seller who is under 18.
#
# Stripe will not verify a minor as the sole person on a payout account: when the account
# representative's date of birth says they are 13-17, Stripe raises a requirement for a second
# Person with relationship.legal_guardian set, and verifies that person instead. The minor stays
# the account holder, which is the whole point — the alternative is the parent owning the seller's
# Gumroad account outright.
#
# Stripe only offers this in some countries, and not at all in Brazil, where the floor is 18 with
# no guardian path. Storing a guardian therefore does not by itself mean the seller's country
# supports one; the country gate lives with the payout setup that consumes this.
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

  # Erasure is a column-for-column obligation, so every column on this table is classified here and
  # a spec asserts the two lists still cover it. A column added later fails that spec rather than
  # silently outliving erasure.
  ERASED_ON_ANONYMIZE = %w[
    first_name
    last_name
    email
    phone
    date_of_birth
    street_address
    city
    state
    zip_code
    country
    country_code
    nationality
    individual_tax_id
    stripe_tos_ip
  ].freeze

  # stripe_person_id is the handle for the copy Stripe holds, so nulling it would orphan that copy
  # rather than erase it — the Stripe sync in a later PR is what deletes the remote Person. The
  # acceptance flag and timestamp stay with it as the record that an adult did once take
  # responsibility; their IP address is in the erased list above, being personal data and nothing else.
  RETAINED_ON_ANONYMIZE = %w[
    id
    user_id
    stripe_person_id
    stripe_tos_accepted
    stripe_tos_accepted_at
    deleted_at
    created_at
  ].freeze

  # Compliance revisions are immutable, so a seller who edits their details leaves several rows
  # pointing at the same guardian. restrict_with_error rather than nullify: silently clearing
  # guardian_id would turn historical revisions incomplete with nothing recording why, and it would
  # write straight past the Immutable guard. A guardian who must go away is anonymized in place by
  # the erasure path below, which keeps the link intact.
  has_many :user_compliance_infos, dependent: :restrict_with_error

  # One guardian belongs to exactly one seller, so erasing that seller can never reach into another
  # seller's compliance details. Without this the schema would let two sellers share a row and one
  # erasure would anonymize the other's guardian, leaving them silently unverifiable.
  belongs_to :user

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
  # Stripe requires the guardian, not the minor, to accept them. The tax identifier is too — it is
  # what Stripe verifies the guardian against, and without it the account stalls on a requirement
  # rather than being ready.
  #
  # A soft-deleted guardian is never complete. Nothing clears guardian_id when a guardian is
  # removed (the link is deliberately kept for the compliance history), so without this check a
  # seller whose guardian had been removed would still look ready for payouts.
  def has_completed_info?
    alive? &&
      first_name.present? &&
      last_name.present? &&
      email.present? &&
      date_of_birth.present? &&
      street_address.present? &&
      city.present? &&
      (!state_required? || state.present?) &&
      zip_code.present? &&
      country.present? &&
      has_individual_tax_id? &&
      stripe_tos_accepted?
  end

  # Removes the guardian's own identifying details while keeping the row, so the compliance
  # revisions that reference it stay intact and auditable. The guardian is a third party who never
  # agreed to anything beyond taking responsibility for one seller's account, so their details go
  # when the seller's do. What survives, and why, is ERASED/RETAINED_ON_ANONYMIZE above.
  def anonymize!
    update_columns(ERASED_ON_ANONYMIZE.index_with(nil).merge("updated_at" => Time.current))
  end

  def has_individual_tax_id?
    individual_tax_id.present?
  end
  alias_method :has_individual_tax_id, :has_individual_tax_id?

  private
    # Stripe asks for a state only where it has a subdivision list, and rejects one elsewhere. Reuses
    # the beneficial-owner list rather than restating it: a guardian is a Person on the same account,
    # so a second copy of this list would be free to drift from the one we actually send Stripe.
    #
    # Derives the code from country rather than reading country_code, which is only filled in by the
    # before_validation hook and so is still nil on an unsaved record.
    def state_required?
      alpha2 = country_code.presence || Compliance::Countries.find_by_name(country)&.alpha2
      StripeBeneficialOwnersManager::COUNTRIES_WITH_STATE_LIST.include?(alpha2)
    end

    def guardian_is_an_adult
      return if date_of_birth.blank?
      return if date_of_birth <= MINIMUM_AGE.years.ago.to_date

      errors.add :base, "The legal guardian must be at least #{MINIMUM_AGE} years old."
    end

    def set_country_code
      self.country_code = Compliance::Countries.find_by_name(country)&.alpha2
    end
end
