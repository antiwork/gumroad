# frozen_string_literal: true

# The legal guardian's details as the payout settings page and its form endpoint both send them.
#
# One class rather than a hash built in each place, because the two are the same contract read from
# opposite ends: the page prefills the form from this, the form's response replaces the page's copy
# with this. A second shape would let a field the seller just saved silently vanish from the form
# until the next full page load.
class GuardianPresenter
  def initialize(guardian)
    @guardian = guardian
  end

  # Deliberately omits the tax identifier. Strongbox encrypts it with a public key whose private half
  # a web request cannot reach, so the only honest thing to report is whether one is on file — see
  # has_individual_tax_id below, which is what the form uses to decide between "add" and "replace".
  def props
    {
      id: guardian.external_id,
      first_name: guardian.first_name,
      last_name: guardian.last_name,
      email: guardian.email,
      phone: guardian.phone,
      date_of_birth: guardian.date_of_birth&.to_fs(:db),
      street_address: guardian.street_address,
      city: guardian.city,
      state: guardian.state,
      zip_code: guardian.zip_code,
      country: guardian.country,
      nationality: guardian.nationality,
      has_individual_tax_id: guardian.has_individual_tax_id?,
      accepted_terms: guardian.has_accepted_terms?,
      has_completed_info: guardian.has_completed_info?,
    }
  end

  private
    attr_reader :guardian
end
