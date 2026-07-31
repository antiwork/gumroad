# frozen_string_literal: true

# The legal guardian a seller aged 13-17 adds so their payout account can be verified.
#
# Separate from Settings::PaymentsController rather than folded into its form because the guardian
# is a distinct person with their own identity details and their own terms acceptance, and because
# the seller's own compliance record is immutable while the guardian is edited in place. Closer in
# shape to Settings::BeneficialOwnersController, which manages the same kind of second Person on
# the same Stripe account.
class Settings::GuardiansController < Settings::BaseController
  include AuditsPayoutSettingsChanges

  before_action :authorize
  # After authorize deliberately: someone with no right to touch these settings must be turned away
  # before we tell them anything about whether the seller is a minor.
  before_action :ensure_guardian_required

  def create
    guardian = current_seller.guardians.build(guardian_params)
    accept_terms(guardian)

    unless guardian.save
      return render json: { error: guardian.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end

    attach_to_compliance_info!(guardian)
    log_payout_settings_update_by_non_owner("Legal guardian added")
    render json: { guardian: GuardianPresenter.new(guardian).props }, status: :created
  end

  def update
    guardian = current_seller.guardians.alive.find_by_external_id(params[:id])
    return head :not_found if guardian.nil?

    guardian.assign_attributes(guardian_params)
    accept_terms(guardian)

    unless guardian.save
      return render json: { error: guardian.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end

    # A guardian edited after being attached is still the attached guardian, so this re-attach is
    # normally a no-op. It matters for the one case where it is not: a seller whose live compliance
    # revision was replaced (any payout-settings save does that) between adding the guardian and
    # editing them, which would otherwise leave the new revision pointing at no guardian.
    attach_to_compliance_info!(guardian)
    log_payout_settings_update_by_non_owner("Legal guardian updated")
    render json: { guardian: GuardianPresenter.new(guardian).props }
  end

  private
    def authorize
      super([:settings, :payments, current_seller], :update?)
    end

    # Only a seller our payment partner will actually accept a guardian for can add one. Asking
    # anyone else would collect an adult's identity details we have no lawful use for and cannot
    # send anywhere — see UserComplianceInfo#requires_legal_guardian?, which is also what decides
    # whether the form is offered.
    def ensure_guardian_required
      return if current_seller.alive_user_compliance_info&.requires_legal_guardian?
      render json: { error: "A legal guardian isn't required on this account." }, status: :forbidden
    end

    # Attaches the guardian to the seller's LIVE compliance revision, in place. guardian_id is one
    # of the few mutable attributes on that otherwise immutable record (UserComplianceInfo
    # attr_mutable :guardian_id) precisely so adding a guardian does not fork a revision: forking
    # one here would republish the seller's own details as a fresh revision and re-trigger the
    # compliance-request handling attached to that.
    def attach_to_compliance_info!(guardian)
      compliance_info = current_seller.alive_user_compliance_info
      return if compliance_info.nil? || compliance_info.guardian_id == guardian.id

      compliance_info.update!(guardian_id: guardian.id)
    end

    # Records the guardian's acceptance of our payment partner's terms with the date and IP that
    # acceptance actually happened at, because Stripe takes all three together and rejects the
    # block if any is missing (Guardian#has_accepted_terms?).
    #
    # Only ever set, never cleared: an adult who accepted the terms did so, and an unchecked box on
    # a later edit is the form echoing back a value the seller cannot see rather than a withdrawal.
    # Withdrawing is removing the guardian.
    def accept_terms(guardian)
      return unless ActiveRecord::Type::Boolean.new.cast(params.dig(:guardian, :accept_terms))
      return if guardian.stripe_tos_accepted?

      guardian.stripe_tos_accepted = true
      guardian.stripe_tos_accepted_at = Time.current
      guardian.stripe_tos_ip = request.remote_ip
    end

    def guardian_params
      params.require(:guardian).permit(
        :first_name, :last_name, :email, :phone, :date_of_birth,
        :street_address, :city, :state, :zip_code, :country, :nationality,
        :individual_tax_id
      )
    end
end
