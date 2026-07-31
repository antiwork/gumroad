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
    # A second create is the seller's second click, or a stale tab, not a request for a second
    # guardian: the compliance record holds exactly one and repointing it is refused. Treated as an
    # edit of the one already attached, so the retry succeeds instead of 500ing and leaving an
    # orphaned row holding an adult's identity details.
    existing = current_seller.alive_user_compliance_info&.guardian
    return save_guardian(existing) if existing&.alive?

    save_guardian(current_seller.guardians.build, status: :created)
  end

  def update
    guardian = current_seller.guardians.alive.find_by_external_id(params[:id])
    return head :not_found if guardian.nil?

    save_guardian(guardian)
  end

  private
    def authorize
      super([:settings, :payments, current_seller], :update?)
    end

    def save_guardian(guardian, status: :ok)
      guardian.assign_attributes(guardian_params)
      apply_sellers_country(guardian)
      accept_terms(guardian)

      # One transaction so a refused attach cannot leave a saved guardian nothing points at — a row
      # holding an adult's name, date of birth, address and tax id that no surface would ever show
      # the seller again.
      saved =
        begin
          ActiveRecord::Base.transaction do
            raise ActiveRecord::Rollback unless guardian.save

            attach_to_compliance_info!(guardian)
            true
          end
        rescue ActiveRecord::RecordInvalid => e
          guardian.errors.add(:base, e.record.errors.full_messages.to_sentence)
          false
        end

      unless saved
        return render json: { error: guardian.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      # The reason this is here rather than on a model callback: attaching a guardian mutates the
      # live compliance revision in place, so none of the revision-created paths that normally sync
      # an account fire. Without this the seller is told they are done and Stripe never learns the
      # guardian exists, leaving the requirement that stopped their payouts unmet.
      SyncGuardianToStripeJob.perform_async(current_seller.id) if guardian.has_completed_info?

      log_payout_settings_update_by_non_owner(status == :created ? "Legal guardian added" : "Legal guardian updated")
      render json: { guardian: GuardianPresenter.new(guardian.reload).props }, status:
    end

    # Only a seller our payment partner will actually accept a guardian for can add one. Asking
    # anyone else would collect an adult's identity details we have no lawful use for and cannot
    # send anywhere — see UserComplianceInfo#requires_legal_guardian?, which is also what decides
    # whether the form is offered.
    def ensure_guardian_required
      return if !current_seller.has_stripe_account_connected? &&
                current_seller.alive_user_compliance_info&.requires_legal_guardian?
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

    # Derived here rather than submitted: our payment partner adds the guardian as a second person on
    # the seller's own account, so their country is the account's country and the form has no picker
    # for it. Without this the country stays nil, Guardian#has_completed_info? is never satisfied, and
    # the seller fills the form in to no effect — payouts stay blocked with the page reporting success.
    def apply_sellers_country(guardian)
      guardian.country = current_seller.alive_user_compliance_info&.country
    end

    def guardian_params
      params.require(:guardian).permit(
        :first_name, :last_name, :email, :phone, :date_of_birth,
        :street_address, :city, :state, :zip_code, :nationality,
        :individual_tax_id
      )
    end
end
