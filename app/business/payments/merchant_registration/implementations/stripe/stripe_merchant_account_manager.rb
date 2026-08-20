# frozen_string_literal: true

module StripeMerchantAccountManager
  REQUESTED_CAPABILITIES = %w(card_payments transfers)
  CROSS_BORDER_PAYOUTS_ONLY_CAPABILITIES = %w(transfers)
  COUNTRIES_SUPPORTED_BY_STRIPE_CONNECT = ["Australia", "Austria", "Belgium", "Brazil", "Bulgaria", "Canada", "Croatia",
                                           "Cyprus", "Czechia", "Denmark", "Estonia", "Finland", "France",
                                           "Germany", "Gibraltar", "Greece", "Hong Kong", "Hungary", "Ireland", "Italy",
                                           "Japan", "Latvia", "Liechtenstein", "Lithuania", "Luxembourg",
                                           "Malta", "Netherlands", "New Zealand", "Norway", "Poland", "Portugal",
                                           "Romania", "Singapore", "Slovakia", "Slovenia", "Spain", "Sweden", "Switzerland",
                                           "United Arab Emirates", "United Kingdom", "United States"].map { |country_name| Compliance::Countries.find_by_name(country_name).alpha2 }
  ACCOUNT_HOLDER_NAME_SYNC_COUNTRIES = [Compliance::Countries::JPN.alpha2, Compliance::Countries::VNM.alpha2, Compliance::Countries::IDN.alpha2].freeze
  private_constant :ACCOUNT_HOLDER_NAME_SYNC_COUNTRIES

  NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES = [Compliance::Countries::IND.alpha2].freeze

  BANK_SYNC_FAILURE_NOTE_PREFIX = "Stripe bank sync failed"

  # Three reasons Stripe refuses bank details, each needing opposite advice: FORMAT (code
  # unacceptable as typed — only re-entering fixes it), TERMINAL (account itself refused — only a
  # different account will do), DIRECTORY miss (bank not in Stripe's records yet — waiting can fix
  # it, which is what the weekly re-check is for). A directory miss reuses the format codes, so
  # DIRECTORY_MISS_MESSAGE wins over them.
  BANK_DETAILS_FORMAT_REJECTION_CODES = %w[routing_number_invalid account_number_invalid].freeze
  BANK_DETAILS_FORMAT_REJECTION_MESSAGE = /Invalid (routing|account) number/i
  BANK_DETAILS_DIRECTORY_MISS_MESSAGE = /couldn't find (the bank|that)/i

  # Stripe refuses a specific external account outright when it's on the connected account's
  # block list ("...because it is on your block list"). Unlike a format or directory-miss
  # rejection, re-entering the same details never helps — only a DIFFERENT bank account will
  # (gumroad-private#1476), so this gets its own classification: no automated retries, and an
  # email that says so.
  BANK_ACCOUNT_BLOCKED_MESSAGE = /because it is on your block list/i

  # Terminal rejections are the ones where the account itself is refused rather than the way it
  # was typed. `bank_account_unusable` is Stripe's code for "payments or payouts on this account
  # failed before"; the message patterns cover the same condition on error shapes that carry no
  # code, plus banks Stripe cannot pay out to at all.
  BANK_DETAILS_TERMINAL_REJECTION_CODES = %w[bank_account_unusable].freeze
  BANK_DETAILS_TERMINAL_REJECTION_MESSAGE = Regexp.union(
    /previous payments or payouts failed/i,
    /previous attempts to deliver payouts/i,
    /doesn't appear to support payouts/i,
    /unable to support this bank/i
  )

  # Passed to ContactingCreatorMailer#invalid_bank_account so the email can tell the seller
  # whether waiting might help (directory miss), whether they must re-enter the code (format),
  # or whether they need a different bank account entirely (terminal).
  BANK_REJECTION_KIND_FORMAT = "format_rejected"
  # As above, but for a block-listed external account: the seller must use a different account,
  # because correcting or re-entering this one can never succeed.
  BANK_REJECTION_KIND_BLOCKED = "account_blocked"
  BANK_REJECTION_KIND_TERMINAL = "terminal_rejected"
  POSTAL_CODE_FAILURE_NOTE_PREFIX = "Stripe postal code rejected"
  # Prefix for the breadcrumb left when Stripe rejects account creation or an account update
  # for a reason we do not handle specifically. See record_account_rejection_note below.
  ACCOUNT_REJECTION_NOTE_PREFIX = "Stripe rejected payout setup"

  # Marks the seller-facing half of an account-rejection breadcrumb, so the publish block can point
  # at that specific note rather than whatever seller-visible payout note happens to be newest.
  PAYOUT_SETUP_REJECTION_NOTE_FLAG = "payout_setup_rejection"

  # The Stripe field name the note's rejection named (see stripe_rejected_field below), so a later
  # update can tell whether IT resolved this note rather than some unrelated field.
  PAYOUT_SETUP_REJECTED_FIELD_KEY = "payout_setup_rejected_field"

  # Prefix for the breadcrumb left when Stripe refuses the service agreement we derived from the
  # seller's legal-entity country. See update_account_attributes below.
  SERVICE_AGREEMENT_REJECTION_NOTE_PREFIX = "Stripe rejected service agreement"

  # Stripe validates `tos_acceptance[:service_agreement]` against the country the connected
  # account was created in, not the legal-entity country we derive it from. Probed against the
  # test API: `param` names the field and `code` is nil, so `param` is the discriminator and the
  # message is the fallback for older error shapes.
  SERVICE_AGREEMENT_REJECTION_PARAM = "tos_acceptance[service_agreement]"
  private_constant :SERVICE_AGREEMENT_REJECTION_PARAM
  SERVICE_AGREEMENT_UNSUPPORTED_MESSAGE = /tos agreement is not supported/i
  private_constant :SERVICE_AGREEMENT_UNSUPPORTED_MESSAGE

  STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR = "Stripe payouts sync"
  private_constant :STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR

  # How long we wait before emailing a seller that Stripe paused their payouts.
  # Stripe's periodic re-verification sweeps sometimes disable payouts and
  # re-enable them minutes later; the internal pause is applied instantly
  # (money safety), but the email waits out this window so a blip that resolves
  # itself never alarms the seller. A genuine pause is still notified — just
  # this much later, which is immaterial next to Stripe review timelines.
  PAYOUTS_PAUSE_EMAIL_DEBOUNCE_DELAY = 30.minutes

  # Stripe intervention categories (the middle segment of an `interv_*`
  # requirement, e.g. `interv_XXX.rejection_appeal.support`) that mean the
  # seller is inside an appeal window. These are actionable: the webhook
  # handler suspends the seller pending the appeal instead of treating the
  # rejection as final.
  APPEAL_INTERVENTION_CATEGORIES = %w(rejection_appeal supportability_rejection_appeal)

  def self.stripe_payouts_pause_email_type(disabled_reason, fields_needed_present)
    return nil if disabled_reason.to_s.start_with?("rejected.") || disabled_reason == "platform_paused"
    return :action_required if fields_needed_present
    :under_review
  end
  private_class_method :stripe_payouts_pause_email_type

  # Claims at most one pause email per Stripe-disabled episode, surviving admin/payout-method
  # resumes. Marker clears when Stripe re-enables payouts, or when StripePayoutsPausedEmailJob
  # declines to send (see nothing_at_stake?) — so an episode can re-claim after that. Claims
  # action_required on first notice or on escalation from under_review; claims under_review on
  # first notice or de-escalation from action_required (requirements met, payouts still paused
  # pending Stripe's review). Called inside the user lock; returns the email type to schedule
  # after commit, or nil.
  #
  # Each claim rotates stripe_payouts_pause_email_claim_token, and a transition to a never-email
  # state (rejected.*, platform_paused) drops the claim entirely. The scheduled job carries the
  # token it was created with and only sends if it still matches — so a job left over from an
  # earlier or since-changed notice can never send a stale email.
  def self.claim_stripe_payouts_pause_email(merchant_account, pause_email_type)
    already_claimed = merchant_account.stripe_payouts_pause_email_sent
    case pause_email_type
    when :action_required
      return nil if already_claimed == "action_required"
    when :under_review
      # already_claimed == "action_required" falls through: the requirements
      # were satisfied while the account stayed paused, so claim the
      # under-review email. The rotated token invalidates any action-required
      # job still waiting out its debounce window — without this, that stale
      # job would tell the seller to act when nothing is due anymore.
      return nil if already_claimed == "under_review"
    else
      # The account moved to a state this flow never emails about (rejected.*
      # or platform_paused). An email still waiting out its debounce window
      # from before the transition would now contradict the account's state
      # ("please provide information" on a rejected account), so drop the
      # claim — clearing the token invalidates the pending job. Clearing the
      # marker also lets a later actionable phase (e.g. a rejection appeal
      # that reopens verification) email the seller afresh.
      if already_claimed || merchant_account.stripe_payouts_pause_email_claim_token
        merchant_account.update!(stripe_payouts_pause_email_sent: nil, stripe_payouts_pause_email_claim_token: nil)
      end
      return nil
    end
    merchant_account.update!(
      stripe_payouts_pause_email_sent: pause_email_type.to_s,
      stripe_payouts_pause_email_claim_token: SecureRandom.uuid
    )
    pause_email_type
  end
  private_class_method :claim_stripe_payouts_pause_email

  def self.account_holder_name_synced_to_stripe?(user)
    country_code = user.alive_user_compliance_info&.legal_entity_country_code
    ACCOUNT_HOLDER_NAME_SYNC_COUNTRIES.include?(country_code)
  end

  # Use "CEO" as the default title for all Stripe custom connect account owners for now.
  DEFAULT_RELATIONSHIP_TITLE = "CEO"

  # Upper bound when listing an account's beneficial owners. Matches
  # StripeBeneficialOwnersManager::PERSON_LIST_LIMIT and Stripe's own page maximum.
  OWNER_LIST_LIMIT = 100

  # Recorded ownership at or above this counts as accounting for the whole company. Just under 100 to
  # absorb the rounding in shares Stripe and our own form accept with more than two decimals
  # (33.33 x 3 = 99.99); it is a rounding allowance, not slack for a list that is genuinely short.
  # Stripe caps combined ownership at 100%, so the untracked remainder can never exceed 0.5% — far
  # below the 25% share that makes someone a reportable beneficial owner in the first place.
  FULLY_ACCOUNTED_OWNERSHIP_PERCENT = 99.5

  # A just-created local row (Stripe::Account.create still in flight) must keep
  # blocking a second create. Older leftover rows with no Stripe id do not —
  # they are failed creates that never cleaned up, and counting them as an
  # existing account permanently skips self-serve retries.
  STALE_HOLLOW_ACCOUNT_AGE = 10.minutes

  def self.create_account(user, passphrase:, from_admin: false, notify: true)
    tos_agreement = nil
    user_compliance_info = nil
    bank_account = nil
    account_params = {}
    merchant_account = nil

    ActiveRecord::Base.connection.stick_to_primary!
    user.with_lock do
      raise MerchantRegistrationUserNotReadyError.new(user.id, "is not supported yet") unless user.native_payouts_supported?

      discard_stale_hollow_managed_accounts!(user)
      user_has_a_merchant_account = if from_admin
        user_has_stripe_connect_merchant_account?(user)
      else
        blocks_new_managed_account?(user)
      end
      raise MerchantRegistrationUserAlreadyHasAccountError.new(user.id, StripeChargeProcessor.charge_processor_id) if user_has_a_merchant_account
      raise MerchantRegistrationUserNotReadyError.new(user.id, "has not agreed to TOS") if user.tos_agreements.empty?

      tos_agreement = user.tos_agreements.last
      user_compliance_info = user.alive_user_compliance_info
      bank_account = user.active_bank_account

      country_code = user_compliance_info.legal_entity_country_code
      raise MerchantRegistrationUserNotReadyError.new(user.id, "does not have a legal entity country") if country_code.blank?
      raise MerchantRegistrationUserNotReadyError.new(user.id, "is not supported yet") if NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES.include?(country_code)
      country = Country.new(country_code)

      currency = country.payout_currency
      raise MerchantRegistrationUserNotReadyError.new(user.id, "has no default currency defined for it's legal entity's country") if currency.blank?

      # Stripe doesn't let us use non-USD bank accounts in the test environment, so we allow a USD bank account to be associated with a non-USD account
      # outside of production to facilitate testing and debugging.
      raise MerchantRegistrationUserNotReadyError.new(user.id, "has #{bank_account.type} #{bank_account.currency} that != #{country_code} #{currency}.") if Rails.env.production? && bank_account && bank_account.currency != currency

      capabilities = country.stripe_capabilities

      account_params = {
        type: "custom",
        requested_capabilities: capabilities,
        country: country_code,
        default_currency: currency
      }
      account_params.deep_merge!(account_hash(user, tos_agreement, user_compliance_info, passphrase:))
      account_params.deep_merge!(bank_account_hash(bank_account, passphrase:)) if bank_account && !bank_account.is_a?(CardBankAccount)

      merchant_account = MerchantAccount.create!(
        user:,
        country: country_code,
        currency:,
        charge_processor_id: StripeChargeProcessor.charge_processor_id
      )
    end

    stripe_account = Stripe::Account.create(force_utf8_encoding(account_params))

    merchant_account.charge_processor_merchant_id = stripe_account.id
    merchant_account.save!

    if user_compliance_info.is_business?
      person_params = person_hash(user_compliance_info, passphrase)
      person_params.deep_merge!(relationship: { representative: true, owner: true, title: user_compliance_info.job_title.presence || DEFAULT_RELATIONSHIP_TITLE, percent_ownership: 100 })
      Stripe::Account.create_person(stripe_account.id, force_utf8_encoding(person_params))
    end

    # An under-18 seller can't be verified alone, so the guardian goes on as a second Person.
    # Sync failure must not fail account creation — the merchant account is already live and the
    # guardian is re-synced on every later update_account, so a miss just leaves Stripe's
    # legal-guardian requirement unmet, same as if we'd never tried.
    # Rescue StandardError, not Stripe::StripeError: the sync also writes locally, and a deadlock
    # or lock-wait timeout there must not escape and abort creation before the account is marked
    # alive.
    begin
      StripeGuardianManager.sync(user, stripe_account, passphrase:)
    rescue => e
      ErrorNotifier.notify(e)
    end

    # We need to update with empty full_name_aliases here as setting full_name_aliases is mandatory for Singapore accounts.
    # It is a property on the `person` entity associated with the Stripe::Account.
    # Ref: https://stripe.com/docs/api/persons/object#person_object-full_name_aliases
    if user_compliance_info.country_code == Compliance::Countries::SGP.alpha2
      stripe_person = Stripe::Account.list_persons(stripe_account.id)["data"].last
      Stripe::Account.update_person(stripe_account.id, stripe_person.id, { full_name_aliases: [""] }) if stripe_person.present?
    end

    merchant_account.charge_processor_alive_at = Time.current
    merchant_account.save!

    # Non-Card bank accounts are saved at account creation time.
    #
    # Card bank accounts are saved when we are notified via account.updated event that charges are enabled on the account
    # because token generation fails unless charges are enabled.
    if bank_account && !bank_account.is_a?(CardBankAccount)
      save_stripe_bank_account_info(bank_account, stripe_account)
    end

    begin
      DefaultAbandonedCartWorkflowGeneratorService.new(seller: user).generate if merchant_account.is_a_stripe_connect_account?
    rescue => e
      Rails.logger.error("Failed to generate default abandoned cart workflow for user #{user.id}: #{e.message}")
      ErrorNotifier.notify(e)
    end

    clear_stale_postal_code_failure_notes(user)
    clear_stale_bank_sync_failure_notes(user)
    clear_stale_payout_setup_rejection_notes(user)

    merchant_account
  rescue => e
    if merchant_account.present? && merchant_account.charge_processor_alive_at.nil?
      cleanup_failed_merchant_account(merchant_account)
      # Bank-account, tax-ID, phone-number, JP address/kanji, and postal-code rejections are
      # expected seller-input errors — Stripe's message shows inline on the settings page and the
      # seller can just fix it (bank/postal-code rejections also get a payout-note breadcrumb
      # below, and postal codes are auto-retried weekly by RetryStripeRejectedPayoutSetupsJob).
      # Don't page Sentry for them; only unexpected failures should alert.
      ErrorNotifier.notify(e) unless bank_account_invalid_error?(e) || tax_id_invalid_error?(e) || phone_number_invalid_error?(e) || jp_address_invalid_error?(e) || postal_code_invalid_error?(e)
    end
    record_postal_code_failure_note(user, e) if notify && postal_code_invalid_error?(e)
    record_bank_sync_failure_note(user, e, bank_account:) if notify && bank_account_invalid_error?(e)
    # A seller who has no connected account yet fails here, not in update_account: the settings
    # page calls create_account once the bank account exists, and every rejection used to leave
    # nothing behind except a merchant-account row created and soft-deleted in the same second.
    # Record which field Stripe objected to unless the rejection already has its own dedicated
    # breadcrumb above, so support can read the cause off the account instead of reproducing it.
    record_account_rejection_note(user, e) if notify && undiagnosed_stripe_rejection?(e)
    raise
  end

  # True for Stripe rejections that would otherwise leave no trace. Postal-code and bank-account
  # rejections are excluded — each already records its own more specific note.
  #
  # Only InvalidRequestError counts (matching UpdateUserComplianceInfo's update path): that's the
  # class Stripe uses when it actually objected to something the seller submitted. Other
  # StripeError subclasses (APIConnectionError, RateLimitError, AuthenticationError) mean the
  # request never got a verdict — recording a rejection note for those would blame the seller's
  # data for what was really a transient outage.
  private_class_method
  def self.undiagnosed_stripe_rejection?(error)
    return false unless error.is_a?(Stripe::InvalidRequestError)

    !postal_code_invalid_error?(error) && !bank_account_invalid_error?(error)
  end

  # Our own words for the fields Stripe names in `param`. Stripe's paths ("individual[id_number]")
  # are not what the settings form calls them, and its messages quote the value it refused without
  # ever stating the rule it applied.
  PAYOUT_SETUP_REJECTED_FIELD_LABELS = {
    "phone" => "phone number",
    "support_phone" => "business phone number",
    "id_number" => "Tax ID",
    "tax_id" => "business tax ID",
    "dob" => "date of birth",
    "first_name" => "first name",
    "last_name" => "last name",
  }.freeze
  private_constant :PAYOUT_SETUP_REJECTED_FIELD_LABELS

  # Seller-facing copy for the payout-setup rejections that have no dedicated lane of their own —
  # everything undiagnosed_stripe_rejection? covers. Without it these fall through to Stripe's raw
  # message or nothing at all, and a seller ends up with a saved-looking settings page, no payout
  # rail, and a publish button that blames a missing payment method (gumroad-private#1777).
  #
  # nil for the rejections that are already handled specifically, so a caller can fall through to
  # the postal-code and bank-directory branches without ordering the checks by hand.
  def self.payout_setup_rejection_seller_message(error, user)
    return unless undiagnosed_stripe_rejection?(error)

    field = PAYOUT_SETUP_REJECTED_FIELD_LABELS[stripe_rejected_field(error)]
    [
      field ? "Our payment partner couldn't accept the #{field} you entered." : "Our payment partner couldn't accept the details you entered.",
      us_individual_phone_rule_note(error, user),
      "Please correct it here and save again — until it goes through you have no payout method, which also stops you publishing new products.",
    ].compact.join(" ")
  end

  # Stripe requires the representative's phone to be a US number on a US individual or
  # sole-proprietorship account, and its rejection quotes the number without saying so. Some
  # foreign landlines are accepted, so a seller cannot infer the rule from a retry either.
  def self.us_individual_phone_rule_note(error, user)
    return unless phone_number_invalid_error?(error)

    compliance_info = user&.alive_user_compliance_info
    return unless compliance_info&.legal_entity_country_code == Compliance::Countries::USA.alpha2
    # legal_entity_business_type falls back to sole proprietorship for a non-business account, so
    # this one comparison covers both the individual and the sole-prop cases Stripe applies it to.
    return unless compliance_info.legal_entity_business_type == UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP

    "For a US individual or sole-proprietorship account it has to be a US number, even if you live elsewhere."
  end
  private_class_method :us_individual_phone_rule_note

  def self.stripe_rejected_field(error)
    param = error.respond_to?(:param) ? error.param.to_s : ""
    param.split("[").last.to_s.delete("]").presence
  end
  private_class_method :stripe_rejected_field

  def self.delete_account(merchant_account)
    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    result = stripe_account.delete
    if result.deleted
      merchant_account.charge_processor_deleted_at = Time.current
      merchant_account.save!
    end
    result.deleted
  end

  # Address sub-hash keys whose values carry a postal code Stripe validates.
  ADDRESS_SUBHASH_KEYS = %i[address address_kanji address_kana].freeze
  private_constant :ADDRESS_SUBHASH_KEYS

  def self.update_account(user, passphrase:, notify: true, force_address_resync: false)
    validate_for_update(user)

    stripe_account = Stripe::Account.retrieve(user.stripe_account.charge_processor_merchant_id)
    last_user_compliance_info = UserComplianceInfo.find_by_external_id(stripe_account["metadata"]["user_compliance_info_id"])

    tos_agreement = user.tos_agreements.last
    user_compliance_info = user.alive_user_compliance_info

    last_attributes = account_hash(user, nil, last_user_compliance_info, passphrase:)
    current_attributes = account_hash(user, tos_agreement, user_compliance_info, passphrase:)
    country_code = user_compliance_info.legal_entity_country_code
    last_attributes[:metadata] = {}
    last_attributes[:business_profile] = {}
    if user_compliance_info.is_business?
      last_attributes.delete(:individual)
      if last_attributes[:company].present? && country_code == Compliance::Countries::USA.alpha2
        last_attributes[:company][:structure] = nil
      end
      last_attributes.delete(:business_type) if user_compliance_info.country_code == Compliance::Countries::CAN.alpha2
    else
      last_attributes.delete(:company)
    end
    if last_attributes[:individual].present?
      last_attributes[:individual][:email] = nil
      last_attributes[:individual][:phone] = nil
      last_attributes[:individual][:relationship] = nil if user_compliance_info.country_code == Compliance::Countries::CAN.alpha2
    end
    if last_attributes[:company].present?
      last_attributes[:company][:directors_provided] = nil
      last_attributes[:company][:executives_provided] = nil
      # Mirrors the individual phone above, and load-bearing for the country-mismatch hold-back:
      # a company phone withheld while the countries disagree would otherwise diff out as
      # unchanged on every later save and never be sent again, even once they reconcile.
      last_attributes[:company][:phone] = nil
    end

    diff_attributes = get_diff_attributes(current_attributes, last_attributes)

    # If we have a full SSN, don't send the last 4 digits at the same time. If the last 4 digits are from a previous
    # compliance info and don't match the new full SSN, this will result in an invalid request.
    diff_attributes[:individual].delete(:ssn_last_4) if diff_attributes[:individual] && diff_attributes[:individual][:id_number].present?

    if user_compliance_info.is_individual? && diff_attributes[:individual][:dob].present?
      # Re-add the full DOB field if any part of it is being kept. Stripe handles this field inconsistently and the full DOB
      # must be submitted if any part of it is changing.
      diff_attributes[:individual][:dob] = current_attributes[:individual][:dob]
    end

    if last_user_compliance_info&.is_business? && user_compliance_info.is_individual?
      # Clear structure first - Stripe rejects company[structure] when business_type is "individual"
      if last_user_compliance_info.legal_entity_country_code == Compliance::Countries::USA.alpha2 &&
        last_user_compliance_info.business_type == UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP
        Stripe::Account.update(stripe_account.id, { company: { structure: "" } })
      end

      # Set the company's name to the individual's first and last name so that this is used as the Stripe account name and during payouts
      # Ref: https://github.com/gumroad/web/issues/19882
      diff_attributes[:company] = { name: user_compliance_info.first_and_last_name }
    end

    # Only set structure for US accounts
    if user_compliance_info.is_business? &&
      country_code == Compliance::Countries::USA.alpha2 &&
      user_compliance_info.business_type == UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP
      diff_attributes[:company] ||= {}
      diff_attributes[:company][:structure] = user_compliance_info.business_type
    end

    capabilities = Country.new(user_compliance_info.legal_entity_country_code).stripe_capabilities

    # Always request the capabilities assigned at account creation, plus any additional capabilities that the account already has (such as tax reporting
    # capability that we request "manually" for some accounts during tax season).
    capabilities = capabilities.map(&:to_sym) | stripe_account.capabilities.keys
    diff_attributes[:capabilities] = capabilities.index_with { |capability| { requested: true } }

    entity_key = user_compliance_info.is_business? ? :company : :individual
    switching_to_business = user_compliance_info.is_business? && last_user_compliance_info&.is_individual?

    # A switch that failed partway leaves the account a company still blocked on
    # company.owners_provided, but the metadata marker has already moved forward, so
    # switching_to_business is false on later attempts and nothing repairs it again. Detect the
    # shape from Stripe's live state instead, so the next payout-settings save heals it.
    #
    # An empty owner list alone is a legitimate resting state for an ordinary business account
    # (nobody filled the beneficial-owners form, or no one holds a reportable share) — seeding a
    # 100% owner there would invent a claim the seller never made. Requiring the record
    # IMMEDIATELY BEFORE the live one to be an individual is what distinguishes an interrupted
    # migration from that: a seller who switched years ago and saved again has a business record
    # in that slot, so a legitimate company isn't mistaken for a stuck switch.
    owners_provided_blocking = user_compliance_info.is_business? && !switching_to_business &&
                               owners_provided_blocking_payouts?(stripe_account) &&
                               switched_from_individual_immediately_before?(user, user_compliance_info)

    # nil means the read failed, which is not the same as "nobody owns anything" — the seeding stays
    # off in that case rather than guessing.
    recorded_ownership_percent = owners_provided_blocking ? recorded_ownership_percent_on(stripe_account.id) : nil
    # An owner list holding nobody but the representative, whose share was never set at all, is the
    # fingerprint of a switch that died before it seeded. Once the seller has added anyone under
    # Settings → Payments, a zero-ownership list is a shape they configured, and a representative
    # whose share Stripe holds AS zero is one the seller set to zero themselves — the beneficial-owners
    # form sends 0 when Owner is unchecked. Re-seeding 100% in either case would overwrite a claim
    # they deliberately gave up.
    stuck_mid_migration = (recorded_ownership_percent&.zero? && sole_unseeded_representative?(stripe_account.id)) || false
    seed_representative_ownership = switching_to_business || stuck_mid_migration

    # The other half of the stuck population: a representative who already holds a share, on an
    # account still blocked only because nothing ever attested the list. Seeding would be wrong
    # here — attestation is the whole fix — so the two conditions can't share one flag.
    #
    # A positive share isn't a COMPLETE list: a rep holding 25% still leaves 75% with owners
    # nobody entered, and attesting there would falsely tell Stripe the list is finished. Only the
    # ownership total says a list accounts for the whole company — no UI asks the seller to
    # affirm completeness directly.
    owner_list_complete = seed_representative_ownership || fully_accounted_ownership?(recorded_ownership_percent)

    # Read the ownership Stripe already has on file BEFORE the account update below, because that
    # update rewrites the metadata marker we use to detect the switch (see last_user_compliance_info
    # above). This read has no rescue on purpose: failing here aborts the save before the marker
    # moves, so the seller retries from the same state instead of falling through to the healing
    # path on a later save.
    unclaimed_percent_ownership = seed_representative_ownership ? unclaimed_percent_ownership_on_stripe(stripe_account) : nil

    # On an automated retry the seller's compliance info is usually unchanged, so the postal code is
    # diffed out and Stripe never re-validates it. Re-add the address from the current attributes so a
    # previously rejected postal code is actually re-checked instead of being silently treated as resolved.
    if force_address_resync
      force_address_into_diff!(diff_attributes, current_attributes, entity_key)
    end

    # Same problem, different field — see force_identity_into_diff!. Deliberately NOT scoped to the
    # mismatch: the cohort's natural resolution is the seller correcting their legal-entity country,
    # and on that save the identifier must go back on the payload for the note to ever be retired.
    force_identity_into_diff!(diff_attributes, current_attributes, user)

    # update_person is the only path that retires a representative-scoped note, and it's skipped
    # once the seller isn't a business — so a note from when they were a company would outlive it.
    # Scoped to the transition itself, not every individual save: the two note scopes are
    # deliberately independent (an ordinary individual save must not delete a representative
    # note — see the isolation spec). Ids are snapshotted BEFORE the update for the same reason
    # clear_identity_rejection_notes takes ids rather than re-querying: a note from an overlapping
    # resync is a diagnostic this save has no result for.
    switching_to_individual = !user_compliance_info.is_business? && last_user_compliance_info&.is_business?
    obsolete_representative_note_ids = switching_to_individual ? identity_rejection_note_ids(user, scope: :representative) : []

    account_update = update_account_attributes(user, stripe_account, diff_attributes, notify:, legal_entity_country: country_code)
    updated_stripe_account = account_update.stripe_account

    person_address_submitted = false
    if user_compliance_info.is_business?
      person_address_submitted = update_person(user, stripe_account, last_user_compliance_info&.external_id, passphrase, force_address_resync:, seed_representative_ownership:, unclaimed_percent_ownership:)
      # Stripe keeps a company's payouts blocked on company.owners_provided until the platform
      # states the owner list is complete. Scoped to accounts we found blocked on it; the callee
      # re-reads the ownership before making the statement.
      attest_owners_provided(stripe_account.id) if owner_list_complete && updated_stripe_account && owners_provided_blocking_payouts?(updated_stripe_account)
    else
      # The individual update landed, so representative verification no longer applies and the note
      # is describing an entity Stripe is no longer being asked about. Left in place it reads as a
      # live block to support and keeps force_identity_into_diff!'s retry signal armed forever.
      clear_identity_rejection_notes(user, note_ids: obsolete_representative_note_ids)
    end

    # Re-sync the guardian on every account update, not only when their own details changed: the
    # seller's legal-entity country and date of birth are what decide whether a guardian is required
    # at all, so a change to the seller can start or end that requirement. Guarded the same way as
    # at creation — a Stripe failure here must not lose the seller's own saved details, which are
    # already on the account by this point.
    begin
      StripeGuardianManager.sync(user, stripe_account, passphrase:)
    rescue => e
      ErrorNotifier.notify(e)
    end

    # Keyed on what actually reached Stripe: a held-back address was never re-validated, so clearing
    # the note would report a fix that never happened.
    if person_address_submitted || address_submitted?(account_update.sent_attributes, entity_key)
      clear_stale_postal_code_failure_notes(user)
    end

    # Only the specific field a prior rejection named is what that rejection's note describes —
    # an unrelated accepted field (e.g. only the city changed) resolves nothing about it, and
    # clearing on any success reverts to a seller-visible note vanishing for a still-unfixed
    # rejection (Greptile finding on this PR).
    clear_stale_payout_setup_rejection_notes(user, resolved_fields: submitted_field_names(account_update.sent_attributes))
  rescue Stripe::InvalidRequestError => e
    record_postal_code_failure_note(user, e) if notify && postal_code_invalid_error?(e)
    raise
  end

  # `stripe_account` is nil when nothing was sent, which is also the signal to the owners_provided
  # attestation that there is no fresh requirements payload to judge.
  AccountUpdate = Struct.new(:stripe_account, :sent_attributes)
  private_constant :AccountUpdate

  # `legal_entity_country` must come from the same compliance record the caller built
  # `diff_attributes` from — re-reading it here would filter one snapshot's payload against
  # another's country. Required rather than defaulted: omitting it would silently disable the
  # country guard and send fields Stripe can never accept.
  private_class_method
  def self.update_account_attributes(user, stripe_account, diff_attributes, legal_entity_country:, notify: true)
    account_country = stripe_account_country(stripe_account)
    attributes = diff_attributes
    # The agreement and the legal-entity address are derived from the legal-entity country but
    # validated against the account's, which is immutable — so while those disagree neither can
    # ever be accepted, and the all-or-nothing API takes the whole payload down with them.
    # `tos_acceptance` goes whole rather than just `service_agreement` because Stripe reads an
    # acceptance without an agreement as the full one, and which agreement these sellers belong
    # under is a compliance decision.
    #
    # Identity fields (`individual[id_number]`, `ssn_last_4`, `company[tax_id]`) are validated the
    # same way but are NOT held back — they are SPLIT into their own call below instead. Withholding
    # an identifier can stall the very verification Stripe is waiting on, with no signal that it was
    # never sent; letting it be rejected in isolation keeps the rejection loud while sparing the rest
    # of the payload. gumroad-private#1575.
    identity_attributes = {}
    if account_country_conflicts_with_legal_entity?(account_country, legal_entity_country)
      identity_attributes = only_identity_fields(diff_attributes)
      attributes = without_account_country_validated_fields(diff_attributes)
      attributes = without_identity_fields(attributes) if identity_attributes.present?
      if attributes != diff_attributes
        record_service_agreement_failure_note(user, nil) if notify
        Rails.logger.warn "Holding back country-validated fields for user #{user&.id}: Stripe account country " \
                          "#{account_country.inspect} disagrees with the legal-entity country"
      end
      if attributes.values.all?(&:blank?)
        sent_identity = submit_identity_fields_in_isolation(user, stripe_account, identity_attributes, account_country)
        return AccountUpdate.new(nil, attributes.deep_merge(sent_identity))
      end
    end

    # Snapshot before the call for the same reason the isolated path does: only notes that predate
    # this request describe a state this request can have resolved.
    stale_note_ids = identity_notes_resolved_by(user, attributes)
    updated = Stripe::Account.update(stripe_account.id, force_utf8_encoding(attributes))
    clear_identity_rejection_notes(user, note_ids: stale_note_ids)
    # After the main payload lands, not before: a rejected identifier must not take the fields that
    # would otherwise have succeeded down with it.
    sent_identity = submit_identity_fields_in_isolation(user, stripe_account, identity_attributes, account_country)
    AccountUpdate.new(updated, attributes.deep_merge(sent_identity))
  rescue Stripe::InvalidRequestError => e
    # Keyed off what was actually sent, not the original diff: retrying from `diff_attributes` here
    # would restore the fields the branch above deliberately held back.
    raise unless service_agreement_unsupported_error?(e) && attributes.key?(:tos_acceptance)

    remaining_attributes = attributes.except(:tos_acceptance)
    # The agreement id is the marker saying "this ToS acceptance is on file at Stripe". Stripe
    # rejected the acceptance, so moving it would claim an agreement that does not exist —
    # measured: the retry otherwise lands `tos_agreement_id` on an account whose tos_acceptance
    # is empty. The compliance-info marker does move, because those fields really did land.
    if remaining_attributes[:metadata].is_a?(Hash)
      remaining_attributes = remaining_attributes.merge(
        metadata: remaining_attributes[:metadata].except(:tos_agreement_id)
      )
    end
    record_service_agreement_failure_note(user, e) if notify
    # The note is written once per account, and the weekly retry job passes notify: false, so this
    # log line is the only per-occurrence signal that the affected cohort is growing.
    Rails.logger.warn "Stripe rejected the derived service agreement for user #{user&.id}: #{e.message}"
    # Only the agreement was on the wire, so there is nothing left to push — but the rejection
    # is recorded now, which is the part that was missing.
    return AccountUpdate.new(nil, remaining_attributes) if remaining_attributes.values.all?(&:blank?)

    AccountUpdate.new(
      Stripe::Account.update(stripe_account.id, force_utf8_encoding(remaining_attributes)),
      remaining_attributes
    )
  end

  private_class_method
  def self.stripe_account_country(stripe_account)
    stripe_account.respond_to?(:country) ? stripe_account.country : stripe_account["country"]
  end

  private_class_method
  def self.service_agreement_unsupported_error?(error)
    return false unless error.is_a?(Stripe::InvalidRequestError)

    param = error.respond_to?(:param) ? error.param.to_s : ""
    return param == SERVICE_AGREEMENT_REJECTION_PARAM if param.present?

    # Only reachable on an error shape that names no field: other rejections mention the agreement
    # in passing (capability interactions) and must keep raising.
    error.message.to_s.match?(SERVICE_AGREEMENT_UNSUPPORTED_MESSAGE)
  end

  # True when Stripe would validate country-derived fields against a different country than the one
  # we build them from. The account's country is authoritative and immutable after creation, so
  # this cannot be reconciled from our side.
  private_class_method
  def self.account_country_conflicts_with_legal_entity?(account_country, legal_entity_country)
    return false if account_country.blank? || legal_entity_country.blank?

    account_country.to_s.upcase != legal_entity_country.to_s.upcase
  end

  # The entity hashes the legal-entity address lives under. Removing the address wholesale rather
  # than just its `country` is deliberate: Stripe validates the address as a unit, so a
  # legal-entity street and postal code under a different country's account is the same rejection.
  # Identity fields under these same hashes are removed here too, but they are RE-SENT on their own
  # rather than dropped — see gumroad-private#1575.
  ACCOUNT_COUNTRY_VALIDATED_ENTITY_KEYS = %i[individual company].freeze
  private_constant :ACCOUNT_COUNTRY_VALIDATED_ENTITY_KEYS

  # Stripe validates the phone against the account's country the same way it validates the
  # address, so a foreign number on a mismatched account is refused as "not a valid phone
  # number" — wording that reads like bad seller input and is not. Measured on the
  # gumroad-private#1512 cohort: 12 of 23 resyncs died here, 9 of those numbers already valid
  # E.164, while every country-MATCHED account in the same population holds a foreign number
  # fine. Unlike an identifier there is nothing to gain from an isolated retry: the value can
  # never be accepted while the countries disagree, and withholding it strands no verification.
  COUNTRY_VALIDATED_CONTACT_KEYS = %i[phone].freeze
  private_constant :COUNTRY_VALIDATED_CONTACT_KEYS

  private_class_method
  def self.without_account_country_validated_fields(diff_attributes)
    attributes = diff_attributes.except(:tos_acceptance)

    ACCOUNT_COUNTRY_VALIDATED_ENTITY_KEYS.each do |entity_key|
      entity = attributes[entity_key]
      next unless entity.is_a?(Hash)

      remaining = entity.except(*ADDRESS_SUBHASH_KEYS, *COUNTRY_VALIDATED_CONTACT_KEYS)
      if remaining.empty?
        attributes = attributes.except(entity_key)
      else
        attributes = attributes.merge(entity_key => remaining)
      end
    end

    # The agreement id marks a ToS acceptance as on file at Stripe. We are not sending the
    # acceptance, so advancing it would claim an agreement that does not exist. The
    # compliance-info marker still moves, because the fields under it really do land.
    if attributes[:metadata].is_a?(Hash)
      attributes = attributes.merge(metadata: attributes[:metadata].except(:tos_agreement_id))
    end

    attributes
  end

  # The identity fields Stripe validates against the ACCOUNT's country rather than the legal
  # entity's. Same validation rule as the address, deliberately handled differently — see
  # `submit_identity_fields_in_isolation`.
  IDENTITY_SUBHASH_KEYS = %i[id_number ssn_last_4 tax_id].freeze
  private_constant :IDENTITY_SUBHASH_KEYS

  # Prefix distinct from the service-agreement note: support needs to tell "we withheld your
  # address" from "Stripe has not taken your tax ID", because only the second is the seller's to
  # fix. Worded around acceptance rather than rejection because the same note also marks an
  # identifier whose isolated call never returned a verdict.
  IDENTITY_REJECTION_NOTE_PREFIX = "Stripe has not accepted tax/national ID"

  # Each identifier is a separate Stripe requirement that can be rejected independently, so each
  # gets its own note namespace. Sharing one would let a representative success clear a company
  # rejection that is still blocking verification. The account-level scopes are the entity hashes
  # themselves, so a per-entity call has a note namespace to match.
  IDENTITY_REJECTION_NOTE_SCOPES = (ACCOUNT_COUNTRY_VALIDATED_ENTITY_KEYS + %i[representative]).freeze
  private_constant :IDENTITY_REJECTION_NOTE_SCOPES

  private_class_method
  def self.identity_rejection_note_prefix(scope)
    raise ArgumentError, "unknown identity rejection scope #{scope.inspect}" unless IDENTITY_REJECTION_NOTE_SCOPES.include?(scope)

    "#{IDENTITY_REJECTION_NOTE_PREFIX} (#{scope})"
  end

  private_class_method
  def self.only_identity_fields(diff_attributes)
    ACCOUNT_COUNTRY_VALIDATED_ENTITY_KEYS.each_with_object({}) do |entity_key, identity|
      entity = diff_attributes[entity_key]
      next unless entity.is_a?(Hash)

      present = entity.slice(*IDENTITY_SUBHASH_KEYS).compact_blank
      identity[entity_key] = present if present.any?
    end
  end

  private_class_method
  def self.without_identity_fields(attributes)
    ACCOUNT_COUNTRY_VALIDATED_ENTITY_KEYS.each do |entity_key|
      entity = attributes[entity_key]
      next unless entity.is_a?(Hash)

      remaining = entity.except(*IDENTITY_SUBHASH_KEYS)
      attributes = remaining.empty? ? attributes.except(entity_key) : attributes.merge(entity_key => remaining)
    end
    attributes
  end

  # Send the identifiers as their OWN all-or-nothing calls — one per entity hash, so a rejected
  # `individual[id_number]` cannot also take down a valid `company[tax_id]`. Returns the subset that
  # Stripe accepted, so the caller records only what actually landed.
  #
  # The rejection is swallowed rather than raised on purpose: by the time this runs the rest of the
  # seller's payload is already on the account, and re-raising would surface as a failed save for
  # fields that succeeded. The payout note is what carries the rejection forward — without it a
  # withheld or refused identifier is undiagnosable, which is the failure mode that ruled out simply
  # filtering these fields (gumroad-private#1575).
  private_class_method
  def self.submit_identity_fields_in_isolation(user, stripe_account, identity_attributes, account_country)
    return {} if identity_attributes.blank?

    identity_attributes.select do |entity_key, entity_attributes|
      submit_entity_identity_fields(user, stripe_account, entity_key, entity_attributes, account_country)
    end
  end

  private_class_method
  def self.submit_entity_identity_fields(user, stripe_account, entity_key, entity_attributes, account_country)
    stale_note_ids = identity_rejection_note_ids(user, scope: entity_key)
    Stripe::Account.update(stripe_account.id, force_utf8_encoding(entity_key => entity_attributes))
    clear_identity_rejection_notes(user, note_ids: stale_note_ids)
    true
  rescue Stripe::StripeError => e
    # Note first, then decide whether to re-raise: the main payload has already advanced the
    # compliance marker, so a call that dies without leaving the marker behind is never retried.
    marker_recorded = record_identity_rejection_note(user, e, account_country, scope: entity_key, confirmed: e.is_a?(Stripe::InvalidRequestError))
    Rails.logger.warn "Stripe did not accept the #{entity_key} identity fields for user #{user&.id} on a " \
                      "#{account_country.inspect} account: #{e.class}: #{e.message}"
    # A verdict is the case this method exists to swallow — but only while the marker persisted.
    # Anything else (transport or permission failure, or a marker write that itself failed) the
    # caller still needs to see, because there is no other state left to drive the retry.
    raise unless e.is_a?(Stripe::InvalidRequestError) && marker_recorded
    false
  end

  # One note per reason, refreshed rather than accumulated: the seller retries this save repeatedly
  # and a note per attempt would bury the payout notes.
  #
  # Deliberately NOT gated on the caller's `notify`, unlike the sibling service-agreement and
  # postal-code notes: this note doubles as the retry marker `force_identity_into_diff!` consults,
  # so a rejection first seen on a notify: false sweep would leave no state and never be re-sent.
  #
  # `confirmed: false` means Stripe never judged the identifier (transport, rate limit, permissions)
  # — same retry marker, different claim, because support must not chase a rejection Stripe never
  # made.
  #
  # Returns whether the marker is in place. The caller swallows the Stripe rejection on the strength
  # of this note existing, so a failed write here must not read as success.
  private_class_method
  def self.record_identity_rejection_note(user, error, account_country, scope:, confirmed: true)
    return false if user.blank?

    prefix = identity_rejection_note_prefix(scope)
    detail = error&.message.presence&.to_s&.truncate(300) || "no reason given"
    reason = if confirmed
      "Stripe account country #{account_country.inspect} validates the ID against itself, not the " \
        "seller's legal-entity country"
    else
      "the isolated call failed before Stripe judged the ID (#{error.class})"
    end
    content = "#{prefix} — #{reason}: #{detail}"

    user.with_lock do
      existing = user.comments.with_type_payout_note.alive
                     .where(author_id: GUMROAD_ADMIN_ID)
                     .where("content LIKE ?", "#{prefix}%")
      next if existing.where(content:).exists?

      existing.each { |note| note.mark_deleted! }
      user.add_payout_note(content:, seller_visible: false)
    end
    true
  rescue => e
    Rails.logger.error "Failed to record Stripe identity-rejection payout note for user #{user&.id}: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
    false
  end

  # The isolated call only runs while the countries disagree, so the cohort's natural resolution —
  # the seller corrects their legal-entity country — takes the identifier back onto the main payload
  # and would otherwise leave the note behind forever, pointing support at a verification that is no
  # longer blocked. Only entities whose identifier is actually on this payload are cleared.
  private_class_method
  def self.identity_notes_resolved_by(user, attributes)
    ACCOUNT_COUNTRY_VALIDATED_ENTITY_KEYS.flat_map do |entity_key|
      entity = attributes[entity_key]
      next [] unless entity.is_a?(Hash) && entity.slice(*IDENTITY_SUBHASH_KEYS).compact_blank.any?

      identity_rejection_note_ids(user, scope: entity_key)
    end
  end

  # Snapshot of the notes this scope's clear is allowed to remove, taken BEFORE the Stripe call.
  private_class_method
  def self.identity_rejection_note_ids(user, scope:)
    return [] if user.blank?

    prefix = identity_rejection_note_prefix(scope)
    user.comments.with_type_payout_note.alive
        .where(author_id: GUMROAD_ADMIN_ID)
        .where("content LIKE ?", "#{prefix}%")
        .pluck(:id)
  rescue => e
    Rails.logger.error "Failed to read Stripe identity-rejection payout notes for user #{user&.id}: #{e.class}: #{e.message}"
    []
  end

  # The identifier landed, so a note saying it was refused now describes a resolved state. Leaving it
  # would keep support chasing a verification that is no longer blocked.
  #
  # Deletes by the id snapshot rather than re-running the scope query, because two resyncs for the
  # same seller overlap: a rejection recorded while our call was in flight is a diagnostic we have no
  # result for, and re-querying here would delete it and leave the seller blocked with nothing on the
  # account saying why. Held under the same lock as the writer so a replacement mid-clear is ordered.
  private_class_method
  def self.clear_identity_rejection_notes(user, note_ids:)
    return if user.blank? || note_ids.blank?

    user.with_lock do
      user.comments.alive.where(id: note_ids).each { |note| note.mark_deleted! }
    end
  rescue => e
    Rails.logger.error "Failed to clear Stripe identity-rejection payout note for user #{user&.id}: #{e.class}: #{e.message}"
  end

  # One breadcrumb per account, not per attempt: the resync runs on every compliance change and
  # the mismatch does not resolve on its own, so re-noting it would bury the payout notes. Two
  # resyncs can be in flight for the same seller, so the look-then-write has to hold the user row.
  private_class_method
  def self.record_service_agreement_failure_note(user, error)
    return if user.blank?

    detail = error.respond_to?(:message) && error&.message.present? ?
      error.message.to_s.truncate(300) :
      "the Stripe account's country does not match the seller's legal-entity country, " \
      "so the service agreement and legal-entity address cannot be accepted on it"

    user.with_lock do
      next if user.comments
                  .with_type_payout_note
                  .alive
                  .where(author_id: GUMROAD_ADMIN_ID)
                  .where("content LIKE ?", "#{SERVICE_AGREEMENT_REJECTION_NOTE_PREFIX}%")
                  .exists?

      user.add_payout_note(
        content: "#{SERVICE_AGREEMENT_REJECTION_NOTE_PREFIX} — #{detail}",
        seller_visible: false
      )
    end
  rescue => e
    Rails.logger.error "Failed to record Stripe service-agreement payout-note breadcrumb for user #{user&.id}: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
  end

  def self.update_person(user, stripe_account, last_user_compliance_info_id, passphrase, force_address_resync: false, seed_representative_ownership: nil, unclaimed_percent_ownership: nil)
    stripe_person = Stripe::Account.list_persons(stripe_account.id, relationship: { representative: true }, limit: 1)["data"].first
    return if stripe_person.nil?

    last_user_compliance_info = UserComplianceInfo.find_by_external_id(last_user_compliance_info_id)
    user_compliance_info = user.alive_user_compliance_info

    current_attributes = person_hash(user_compliance_info, passphrase)
    current_attributes.deep_merge!(relationship: { representative: true })
    seed_representative_ownership = last_user_compliance_info&.is_individual? && user_compliance_info.is_business? if seed_representative_ownership.nil?
    if seed_representative_ownership
      # Switching a seller from individual to business normally means one person who owns the whole
      # company, so the representative is seeded as a 100% owner. That is wrong whenever the Stripe
      # account already has beneficial owners on it — someone the seller added under Settings →
      # Payments, or people left over from an earlier business registration. Stripe rejects the
      # entire account update with "The total combined ownership of the company would exceed 100
      # percent" when the representative's share plus theirs goes over 100, so the switch fails
      # outright and the seller is left mid-migration. Claim only the ownership nobody else holds,
      # and claim none at all when the existing owners already account for the whole company.
      relationship = { title: user_compliance_info.job_title.presence || DEFAULT_RELATIONSHIP_TITLE }
      unclaimed = unclaimed_percent_ownership || unclaimed_percent_ownership_on_stripe(stripe_account)
      if unclaimed.positive?
        relationship[:owner] = true
        relationship[:percent_ownership] = unclaimed
      end
      current_attributes.deep_merge!(relationship:)
    end
    diff_attributes = current_attributes
    last_attributes = person_hash(last_user_compliance_info, passphrase)

    if last_attributes
      last_attributes[:email] = nil
      last_attributes[:phone] = nil
      diff_attributes = get_diff_attributes(current_attributes, last_attributes)
    end

    if diff_attributes[:dob].present?
      # Re-add the full DOB field if any part of it is being kept. Stripe handles this field inconsistently and the full DOB
      # must be submitted if any part of it is changing.
      diff_attributes[:dob] = current_attributes[:dob]
    end

    # See update_account: force the representative's address back into the diff so an automated retry
    # actually re-validates a previously rejected representative postal code.
    force_address_into_diff!(diff_attributes, { person: current_attributes }, :person) if force_address_resync

    # `update_person` is a SEPARATE all-or-nothing payload, and it carried no country filter at all:
    # a representative identifier Stripe validates against the account country would take the whole
    # person update down with it, losing name/dob/address changes that were fine. Split the
    # identifier out on a mismatched account for the same reason as the account update above
    # (gumroad-private#1575).
    person_identity_attributes = {}
    account_country = stripe_account_country(stripe_account)
    # Same retry gap as the account path, and unscoped for the same reason — see
    # force_identity_into_diff!. Hand-rolled because the person payload is flat, not keyed by entity.
    if identity_rejection_note_ids(user, scope: :representative).any?
      outstanding = current_attributes.slice(*IDENTITY_SUBHASH_KEYS).compact_blank
      diff_attributes = diff_attributes.merge(outstanding) if outstanding.present?
      diff_attributes = diff_attributes.except(:ssn_last_4) if diff_attributes[:id_number].present?
    end
    if account_country_conflicts_with_legal_entity?(account_country, user_compliance_info.legal_entity_country_code)
      person_identity_attributes = diff_attributes.slice(*IDENTITY_SUBHASH_KEYS).compact_blank
      diff_attributes = diff_attributes.except(*IDENTITY_SUBHASH_KEYS) if person_identity_attributes.present?
    end

    # See identity_notes_resolved_by: once the countries agree the identifier rides the main person
    # payload again, and this is the only place left that can retire the note.
    resolved_note_ids = diff_attributes.slice(*IDENTITY_SUBHASH_KEYS).compact_blank.any? ?
      identity_rejection_note_ids(user, scope: :representative) : []

    begin
      Stripe::Account.update_person(stripe_account.id, stripe_person.id, force_utf8_encoding(diff_attributes))
    rescue Stripe::InvalidRequestError => e
      # The unclaimed share was read before the account update above, so a beneficial owner added or
      # enlarged in the window between that read and this call makes our number stale and too large,
      # and Stripe rejects the whole person update. That is the same seller-visible breakage this
      # method exists to prevent, so re-read the live ownership and try once more rather than letting
      # a few seconds of bad luck strand the seller mid-migration. Only retry when we actually sent an
      # ownership share and the retry would send a smaller one, so this can never loop.
      raise unless combined_ownership_exceeded_error?(e) && diff_attributes.dig(:relationship, :percent_ownership).present?

      fresh_unclaimed = unclaimed_percent_ownership_on_stripe(stripe_account)
      raise if fresh_unclaimed >= diff_attributes[:relationship][:percent_ownership]

      if fresh_unclaimed.positive?
        diff_attributes[:relationship][:percent_ownership] = fresh_unclaimed
      else
        # The other owners now account for the entire company, so the representative claims nothing.
        diff_attributes[:relationship].delete(:percent_ownership)
        diff_attributes[:relationship].delete(:owner)
      end
      Stripe::Account.update_person(stripe_account.id, stripe_person.id, force_utf8_encoding(diff_attributes))
    end
    clear_identity_rejection_notes(user, note_ids: resolved_note_ids)
    submit_person_identity_fields_in_isolation(user, stripe_account, stripe_person, person_identity_attributes, account_country)
    ADDRESS_SUBHASH_KEYS.any? { |address_key| diff_attributes[address_key].present? }
  end

  # The `update_person` counterpart of `submit_identity_fields_in_isolation`. Same contract: the
  # rejection is recorded as a payout note rather than raised, because the rest of the person update
  # has already landed by the time this runs.
  private_class_method
  def self.submit_person_identity_fields_in_isolation(user, stripe_account, stripe_person, identity_attributes, account_country)
    return false if identity_attributes.blank?

    stale_note_ids = identity_rejection_note_ids(user, scope: :representative)
    Stripe::Account.update_person(stripe_account.id, stripe_person.id, force_utf8_encoding(identity_attributes))
    clear_identity_rejection_notes(user, note_ids: stale_note_ids)
    true
  rescue Stripe::StripeError => e
    marker_recorded = record_identity_rejection_note(user, e, account_country, scope: :representative, confirmed: e.is_a?(Stripe::InvalidRequestError))
    Rails.logger.warn "Stripe did not accept the representative's identity fields for user #{user&.id} on a " \
                      "#{account_country.inspect} account: #{e.class}: #{e.message}"
    raise unless e.is_a?(Stripe::InvalidRequestError) && marker_recorded
    false
  end

  private_class_method
  # Stripe rejects a person update whose ownership share would push the company's combined ownership
  # over 100%. It surfaces as an InvalidRequestError on the percent_ownership param rather than a
  # dedicated error code, so match on the param plus the message.
  def self.combined_ownership_exceeded_error?(error)
    return false unless error.is_a?(Stripe::InvalidRequestError)

    error.message.to_s.match?(/combined ownership/i) ||
      error.try(:param).to_s.include?("percent_ownership")
  end

  private_class_method
  # How much of the company nobody has claimed yet, ignoring the representative's own recorded share
  # so a partially-completed earlier attempt does not count against them on a retry. Rounds DOWN:
  # under-claiming by a hundredth of a percent is harmless, whereas rounding up past what is actually
  # free is how Stripe's "combined ownership would exceed 100 percent" rejection happens, and our own
  # beneficial-owner form accepts shares with more than two decimals.
  def self.unclaimed_percent_ownership_on_stripe(stripe_account)
    claimed = owner_relationships_on(stripe_account.id)
              .reject { |relationship| relationship[:representative] }
              .sum { |relationship| relationship[:percent_ownership].to_f }
    [(100 - claimed).floor(2), 0].max
  end

  private_class_method
  # Read through to_h: a person Stripe returns without a relationship object at all raises
  # NoMethodError on a plain `person.relationship`, and this must never be the thing that breaks a
  # payout-settings save.
  def self.owner_relationships_on(stripe_account_id)
    persons = Stripe::Account.list_persons(stripe_account_id, relationship: { owner: true }, limit: OWNER_LIST_LIMIT)["data"]
    persons.filter_map { |person| person.to_h[:relationship] }
  end

  private_class_method
  # Whether company.owners_provided is one of the requirements actually holding this account's
  # payouts. eventually_due is deliberately excluded: it lists requirements that only bind at a
  # future volume threshold, so an account with the field there is not blocked and needs no repair.
  def self.owners_provided_blocking_payouts?(stripe_account)
    account = stripe_account.to_h
    company = account[:company] || {}
    return false if company[:owners_provided]

    requirements = account[:requirements] || {}
    blocking = requirements[:currently_due].to_a + requirements[:past_due].to_a
    blocking.include?("company.owners_provided")
  end

  private_class_method
  # Total ownership share recorded on the account, or nil when Stripe could not be read. Callers must
  # treat nil as "unknown" — a failed read must never take down a payout-settings save, and must not
  # be mistaken for a confirmed empty owner list.
  def self.recorded_ownership_percent_on(stripe_account_id)
    owner_relationships_on(stripe_account_id).sum { |relationship| relationship[:percent_ownership].to_f }
  rescue Stripe::StripeError => e
    ErrorNotifier.notify(e)
    nil
  end

  # Whether the recorded shares account for the whole company, which is the only thing that makes the
  # owner list provably complete. nil (a failed read) and a partial total both fail closed: a company
  # whose entered owners hold 25% has 75% belonging to people nobody has listed.
  #
  # Stripe accepts shares with more than two decimals and our own form does too, so sums like
  # 33.33 x 3 land just under 100. The tolerance is there for that rounding, not to wave through a
  # genuinely short list.
  def self.fully_accounted_ownership?(recorded_ownership_percent)
    return false if recorded_ownership_percent.nil?

    recorded_ownership_percent >= FULLY_ACCOUNTED_OWNERSHIP_PERCENT
  end
  private_class_method :fully_accounted_ownership?

  # Whether the representative is the only person on the account AND has no ownership share recorded
  # at all. A switch that died before seeding leaves exactly that shape: Stripe was never told
  # anything about the representative's ownership, so percent_ownership is absent.
  #
  # An explicit 0 is a different account. Unchecking Owner on the beneficial-owners form submits
  # percent_ownership 0, so a stored zero is a share the seller set to zero on purpose, and
  # re-seeding 100% over it would invent a claim they had deliberately given up. Both shapes sum to
  # a zero total, so the caller's total cannot tell them apart — only the presence of the field can.
  #
  # Lists ALL persons, not just owners: a director or executive entered with owner=false is invisible
  # to an owner-scoped read, and overwriting the representative's share on that account would still
  # be inventing a claim. Returns false when Stripe cannot be read, so an unreadable account is never
  # seeded.
  #
  # Indexed rather than dug: Stripe's to_h is shallow, so the relationship is still a StripeObject,
  # which supports [] but raises NoMethodError on dig.
  def self.sole_unseeded_representative?(stripe_account_id)
    persons = Stripe::Account.list_persons(stripe_account_id, limit: OWNER_LIST_LIMIT)["data"]
    return false unless persons.one?

    relationship = persons.first.to_h[:relationship]
    return false unless relationship && relationship[:representative]

    relationship[:percent_ownership].nil?
  rescue Stripe::StripeError => e
    ErrorNotifier.notify(e)
    false
  end
  private_class_method :sole_unseeded_representative?

  # Whether the compliance record immediately preceding the live one was an individual — the shape an
  # interrupted individual-to-business switch leaves behind.
  #
  # Ordered by id rather than filtered by is_business, because a seller who switched long ago and has
  # saved payout settings since has later business records; "an individual record exists somewhere in
  # history" would treat that settled company as mid-migration forever. Soft-deleted records are
  # intentionally included: these are immutable compliance records, so every superseded one is
  # deleted and the previous record is only ever visible through them.
  #
  # Takes the previous record whatever its is_business value and asks it, so a legacy row with the
  # column unset reads as individual exactly as it does everywhere else (is_individual? is
  # !is_business?) instead of being skipped in favour of an older record.
  def self.switched_from_individual_immediately_before?(user, live_user_compliance_info)
    previous = user.user_compliance_infos
                   .where.not(id: live_user_compliance_info.id)
                   .order(id: :desc)
                   .first
    previous&.is_individual? || false
  end
  private_class_method :switched_from_individual_immediately_before?

  private_class_method
  # Stripe holds a company account's payouts on company.owners_provided until the platform states
  # that the owner list is complete, and nothing else in the codebase states it — so seeding the
  # representative correctly is not by itself enough to unblock a seller.
  #
  # The ownership is re-read here rather than trusted from the caller's earlier read: the caller
  # decides to attest from its INTENT to seed, and update_person returns silently without seeding
  # when the account has no representative person. Reading after that call is what makes this a
  # statement about what Stripe actually holds. Never attest a list that does not account for the
  # whole company — a partial or unreadable list would be a false statement to Stripe, and it would
  # hide a switch that seeded nobody behind a cleared requirement.
  def self.attest_owners_provided(stripe_account_id)
    return unless fully_accounted_ownership?(recorded_ownership_percent_on(stripe_account_id))

    Stripe::Account.update(stripe_account_id, { company: { owners_provided: true } })
  rescue Stripe::StripeError => e
    # The seller's compliance details are already saved on Stripe at this point; only the
    # attestation is missing, and the next save retries it. Raising here would make a save the
    # seller watches succeed look like an error.
    ErrorNotifier.notify(e)
  end

  private_class_method
  def self.force_address_into_diff!(diff_attributes, current_attributes, key)
    source = current_attributes[key]
    return diff_attributes unless source.is_a?(Hash)

    target = key == :person ? diff_attributes : (diff_attributes[key] ||= {})
    ADDRESS_SUBHASH_KEYS.each do |address_key|
      address = source[address_key]
      target[address_key] = address if address.present?
    end
    diff_attributes
  end

  # Put the current identity fields back into the diff when an unresolved rejection note says Stripe
  # has not accepted them. The isolated call swallows its rejection so the compliance marker advances
  # anyway; without this, an unchanged save produces no identity diff and the rejected identifier is
  # never re-sent. The note is cleared on acceptance, so this stops on its own.
  private_class_method
  def self.force_identity_into_diff!(diff_attributes, current_attributes, user)
    ACCOUNT_COUNTRY_VALIDATED_ENTITY_KEYS.each do |entity_key|
      next if identity_rejection_note_ids(user, scope: entity_key).empty?

      source = current_attributes[entity_key]
      next unless source.is_a?(Hash)

      identity = source.slice(*IDENTITY_SUBHASH_KEYS).compact_blank
      next if identity.empty?

      target = (diff_attributes[entity_key] ||= {})
      identity.each { |key, value| target[key] = value }
    end

    # Mirrors the guard in `update_account`: a full id_number and a stale ssn_last_4 on the same
    # payload is itself an invalid request, and re-adding both is exactly how that happens here.
    diff_attributes[:individual]&.delete(:ssn_last_4) if diff_attributes.dig(:individual, :id_number).present?

    diff_attributes
  end

  private_class_method
  def self.address_submitted?(diff_attributes, entity_key)
    entity = diff_attributes[entity_key]
    return false unless entity.is_a?(Hash)

    ADDRESS_SUBHASH_KEYS.any? { |address_key| entity[address_key].present? }
  end

  # Key names actually sent to Stripe, at every nesting depth — used to tell whether a rejection
  # note's specific field (see stripe_rejected_field below) was part of THIS submission.
  # stripe_rejected_field records the LAST bracket segment of Stripe's param, which for a
  # compound field like "individual[dob]" is the parent key "dob", not one of its day/month/year
  # leaves — so parent keys must be included here too, not just leaves (Greptile finding).
  private_class_method
  def self.submitted_field_names(sent_attributes)
    return [] unless sent_attributes.is_a?(Hash)

    sent_attributes.flat_map do |key, value|
      value.is_a?(Hash) ? [key.to_s] + submitted_field_names(value) : key.to_s
    end
  end

  def self.get_diff_attributes(current_attributes, last_attributes)
    # Stripe will error if we send unchanged data for locked fields of a verified user.
    # To work around this, we send only attributes that are not in last_attributes or are different in current_attributes.
    # Attributes that are the same will be marked with the object, then removed after merging.
    reject_marker = Object.new
    diff_attributes = current_attributes.deep_merge(last_attributes) do |_key, current_value, last_value|
      if current_value == last_value
        reject_marker
      else
        current_value
      end
    end
    # Remove attributes that were marked for rejection, or are an empty hash.
    diff_attributes.deep_reject! do |_key, value|
      if value.is_a?(Hash)
        value.empty?
      else
        value == reject_marker
      end
    end
  end

  def self.update_bank_account(user, passphrase:, notify: true)
    validate_for_update(user)

    bank_account = user.active_bank_account
    raise MerchantRegistrationUserNotReadyError.new(user.id, "does not have a bank account") if bank_account.nil?

    stripe_account = Stripe::Account.retrieve(user.stripe_account.charge_processor_merchant_id)
    if stripe_account["metadata"]["bank_account_id"] == bank_account.external_id
      return :noop_metadata_match unless account_holder_name_synced_to_stripe?(bank_account.user)

      stripe_external_account = stripe_account["external_accounts"]&.first
      stripe_holder_name = stripe_external_account && stripe_external_account["account_holder_name"]
      return :noop_metadata_match if stripe_holder_name == bank_account.account_holder_full_name
    end

    attributes = bank_account_hash(bank_account, stripe_account:, passphrase:)
    Stripe::Account.update(stripe_account.id, force_utf8_encoding(attributes))

    save_stripe_bank_account_info(bank_account, stripe_account.refresh)
    clear_stale_bank_sync_failure_notes(user)
    :synced
  rescue Stripe::InvalidRequestError => e
    # Stripe returns "Gumroad has blocked payments on this account..." when the connected
    # account was rejected by Gumroad itself (a platform-level risk block). No bank account
    # update can succeed until that block is lifted, so this outcome is expected: don't page
    # Sentry and don't leave a bank-sync failure note that would trigger automated retries.
    if e.message.to_s.include?("has blocked payments on this account")
      return :account_blocked_by_platform
    end

    if e.code == "incorrect_account_holder_name"
      ContactingCreatorMailer.invalid_account_holder_name(user.id).deliver_later(queue: "critical") if notify
      return :invalid_account_holder_name
    end
    failure_note = record_bank_sync_failure_note(user, e, bank_account:) if notify
    # bank_account_invalid_error? recognizes rejections of the seller's bank details themselves
    # (unknown bank for a BIC or routing code, invalid account number). Stripe marks these via
    # the error's code or param (for example param "bank_account[routing_number]" on "We
    # couldn't find the bank for that BIC"). They are expected seller-input errors, exactly
    # like during account creation: the seller gets emailed and a retryable payout note was
    # recorded above, so they must not page Sentry. The message-string checks that follow
    # cover older rejection shapes that carry no code or param.
    if e.code == "bank_account_unusable" || bank_account_invalid_error?(e) || e.message["Invalid account number"] || e.message["couldn't find that transit"] || e.message["previous attempts to deliver payouts"] || e.message["previous payments or payouts failed"] || e.message["doesn't appear to support payouts"]
      if notify
        rejection_kind = bank_rejection_kind_for(e)
        ContactingCreatorMailer.invalid_bank_account(user.id, rejection_kind, e.message.to_s, bank_account.id).deliver_later(queue: "critical")
        mark_bank_sync_note_seller_notified!(failure_note)
      end
      return :invalid_bank_account
    end

    ErrorNotifier.notify(e)
    :stripe_invalid_request
  rescue Stripe::CardError => e
    record_bank_sync_failure_note(user, e, bank_account:) if notify
    # A CardError here means the debit card used for payouts was declined by the network, not
    # that a bank code was mistyped, so this is never a format rejection.
    ContactingCreatorMailer.invalid_bank_account(user.id).deliver_later(queue: "critical") if notify
    :card_not_supported
  rescue Stripe::StripeError => e
    Rails.logger.error "Stripe error (#{e.class.name}) request ID #{e.request_id} when updating bank account #{bank_account&.id} for stripe account #{stripe_account&.inspect}"
    ErrorNotifier.notify(e)
    :stripe_unknown_error
  end

  private_class_method
  # Returns the note so callers that go on to email the seller can mark it — see
  # mark_bank_sync_note_seller_notified!. The structured json_data fields are what the
  # classifiers read; the human-readable content is for support staff reading the account.
  def self.record_bank_sync_failure_note(user, error, bank_account:)
    code = error.respond_to?(:code) ? error.code : nil
    message = error.message.to_s
    user.add_payout_note(
      content: "#{BANK_SYNC_FAILURE_NOTE_PREFIX}: #{code || 'unknown'} — #{message.truncate(200)}",
      seller_visible: false,
      # In the insert, not a follow-up save — see add_payout_note. bank_account is the row the
      # caller submitted rather than a re-read: the sync makes network calls, so by now the
      # seller's active row may already be the replacement.
      json_data: {
        "stripe_error_code" => code,
        "stripe_error_message" => message,
        "bank_account_id" => bank_account&.id
      }
    )
  rescue => e
    Rails.logger.error "Failed to record payout-note breadcrumb for user #{user&.id}: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
    nil
  end

  # Records on the note that the seller has already been told about this rejection. The
  # automated retry loop reads this before abandoning a note: an unmarked note (one recorded
  # by account creation, which re-raises instead of emailing, or one recorded before this
  # field existed) means the seller has heard nothing and must be emailed first.
  def self.mark_bank_sync_note_seller_notified!(note)
    return if note.nil?

    note.json_data["seller_notified"] = true
    note.save!
  rescue => e
    Rails.logger.error "Failed to mark bank sync note #{note&.id} as notified: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
  end

  # Which "we can't use this bank account" story the seller should be told, or nil when it's the
  # directory-miss case the default email copy already describes.
  #
  # Order matters. A block is the narrowest claim — Stripe named this one account — so it is
  # asked first. Terminal outranks format because Stripe reuses format codes for accounts it
  # refuses outright, and telling that seller to re-type digits is an infinite loop.
  def self.bank_rejection_kind_for(error)
    return BANK_REJECTION_KIND_BLOCKED if bank_account_blocked?(error)
    return BANK_REJECTION_KIND_TERMINAL if bank_details_terminal_rejection?(error)
    return BANK_REJECTION_KIND_FORMAT if bank_details_format_rejection?(error)
    nil
  end

  # Format grounds: the value as typed can never be accepted, so waiting cannot fix it and the
  # seller must re-enter the code.
  def self.bank_details_format_rejection?(error)
    code = error.respond_to?(:code) ? error.code : nil
    format_rejection_signals?(code:, message: error.message.to_s)
  end

  # The account itself is refused, not the way it was typed. Separate from the format predicate
  # because "fix your code" would loop the seller forever on an account that can never be accepted.
  def self.bank_details_terminal_rejection?(error)
    code = error.respond_to?(:code) ? error.code : nil
    terminal_rejection_signals?(code:, message: error.message.to_s)
  end

  # Same question as bank_details_terminal_rejection?, answered from the payout-note breadcrumb
  # rather than a live Stripe error.
  def self.bank_details_terminal_rejection_note?(note)
    code, message = bank_sync_note_error_details(note)
    terminal_rejection_signals?(code:, message:)
  end

  # Same question as bank_details_format_rejection?, answered from the payout-note breadcrumb.
  # Notes predating the structured json_data fields only have the truncated human-readable
  # content, so a directory-miss phrase past 200 chars is invisible there — prefer the fields.
  def self.bank_details_format_rejection_note?(note)
    code, message = bank_sync_note_error_details(note)
    format_rejection_signals?(code:, message:)
  end

  # True when Stripe could not match the routing value against its bank directory. Distinct from
  # the format and terminal cases: the value may be perfectly real and simply absent from Stripe's
  # records, so the advice is to check it and wait, not to replace the account.
  def self.bank_details_directory_miss?(error)
    bank_details_directory_miss_message?(error.message)
  end

  # Same question answered from the payout-note breadcrumb, for the surfaces that read the note
  # rather than a live error.
  def self.bank_details_directory_miss_note?(note)
    _code, message = bank_sync_note_error_details(note)
    bank_details_directory_miss_message?(message)
  end

  # Same question answered from the message string alone, for the mailer, which receives Stripe's
  # message rather than the error object.
  def self.bank_details_directory_miss_message?(message)
    message.to_s.match?(BANK_DETAILS_DIRECTORY_MISS_MESSAGE)
  end

  # The sentence appended to a directory-miss rejection so it names the values that were refused.
  #
  # Stripe's own message ("We couldn't find the bank for that bank/branch code") names neither the
  # values nor which of the two boxes they came from, and the page shows nothing else — so a seller
  # cannot tell whether we objected to their bank code, their branch code, or the bank itself. The
  # gumroad-private#1550 seller re-saved six times in eleven minutes cycling BIC spellings.
  #
  # For the countries that collect both halves, Stripe does not say WHICH one it could not match:
  # the error's param is the combined `bank_account[routing_number]` and there is no directory
  # endpoint to test either half against. So name both values and give the head-office trap as
  # something to rule out, never as the diagnosis. Single-value countries have no such ambiguity
  # and get the value alone.
  #
  # Returns nil when there is nothing specific to say, so callers can append it unconditionally.
  def self.bank_directory_miss_detail(bank_account)
    fields = bank_account&.routing_fields_sentence
    return if fields.blank?

    detail = "The details we sent were #{fields}."
    return detail unless bank_account.has_separate_branch_code?

    "#{detail} Our payment partner doesn't tell us which of the two it couldn't match, so please " \
      "check both against the codes your own branch uses — a bank's head-office code is often not " \
      "accepted as a branch code, even when the bank publishes it."
  end

  # The message shown inline on the settings page when a save is refused as a directory miss, or
  # nil when this rejection is something else (so callers keep Stripe's own message).
  #
  # Stripe's string is handed to the seller verbatim today, and on its own it is unactionable: it
  # names no value, no field, and no next step. Prefix it with our own account of what we sent and
  # what to do about it.
  def self.bank_directory_miss_seller_message(error, bank_account)
    return unless error.is_a?(Stripe::InvalidRequestError)
    return unless bank_details_directory_miss?(error)

    detail = bank_directory_miss_detail(bank_account)
    weeks = RetryStripeRejectedPayoutSetupsJob::RETRY_WINDOW_WEEKS
    [
      "Our payment partner couldn't match your bank details against its records.",
      detail,
      "Please double-check them and save again. If you're sure they're correct (for example, a " \
        "newly opened account or a recently added branch), you don't need to do anything — we'll " \
        "re-check once a week for up to #{weeks} weeks and only reach out if it still doesn't verify.",
    ].compact.join(" ")
  end

  # True when Stripe refused this specific external account because it is block-listed on the
  # connected account (see BANK_ACCOUNT_BLOCKED_MESSAGE). Distinct from a format rejection: the
  # details are valid, so there is nothing for the seller to correct and nothing for waiting to
  # fix. They have to add a different account.
  def self.bank_account_blocked?(error)
    error.message.to_s.match?(BANK_ACCOUNT_BLOCKED_MESSAGE)
  end

  # Same question answered from the payout-note breadcrumb rather than a live Stripe error, so
  # the weekly retry loop can recognise a block it did not itself observe. Mirrors
  # bank_details_format_rejection_note?, including the fallback to the note's human-readable
  # content for notes written before the structured fields existed.
  def self.bank_account_blocked_note?(note)
    _code, message = bank_sync_note_error_details(note)
    message.to_s.match?(BANK_ACCOUNT_BLOCKED_MESSAGE)
  end

  def self.bank_sync_note_error_details(note)
    json_data = note.respond_to?(:json_data) ? note.json_data : {}
    content = note.respond_to?(:content) ? note.content.to_s : note.to_s

    if json_data.key?("stripe_error_message")
      [json_data["stripe_error_code"], json_data["stripe_error_message"].to_s]
    else
      # Search BOTH code lists against the legacy content string — scoping to one list would make
      # the other classifier blind to notes predating the structured fields.
      known_codes = BANK_DETAILS_FORMAT_REJECTION_CODES + BANK_DETAILS_TERMINAL_REJECTION_CODES
      [known_codes.find { |code| content.include?(code) }, content]
    end
  end

  def self.format_rejection_signals?(code:, message:)
    return false if message.match?(BANK_DETAILS_DIRECTORY_MISS_MESSAGE)
    # A terminal rejection can share a code with a format rejection (Stripe reuses
    # account_number_invalid for "this account previously failed"), and telling that seller to
    # re-type their digits would loop them forever. Terminal wins.
    return false if terminal_rejection_signals?(code:, message:)

    code.to_s.in?(BANK_DETAILS_FORMAT_REJECTION_CODES) || message.match?(BANK_DETAILS_FORMAT_REJECTION_MESSAGE)
  end

  def self.terminal_rejection_signals?(code:, message:)
    # Unlike a format rejection, a directory miss does not override this: "we couldn't find the
    # bank" is a waiting problem, but it never carries a terminal code or message, so there is
    # nothing to disambiguate here.
    code.to_s.in?(BANK_DETAILS_TERMINAL_REJECTION_CODES) || message.match?(BANK_DETAILS_TERMINAL_REJECTION_MESSAGE)
  end

  # False when nobody emailed the seller about this note — account creation records one and
  # re-raises instead of emailing, and older notes carry no answer. The retry loop must email
  # before abandoning such a note or the seller is never told what to change.
  def self.bank_sync_note_seller_notified?(note)
    note.respond_to?(:json_data) && note.json_data["seller_notified"] == true
  end

  private_class_method
  def self.clear_stale_bank_sync_failure_notes(user)
    user.comments
        .with_type_payout_note
        .alive
        .where(author_id: GUMROAD_ADMIN_ID)
        .where("content LIKE ?", "#{BANK_SYNC_FAILURE_NOTE_PREFIX}%")
        .update_all(deleted_at: Time.current)
  rescue => e
    Rails.logger.error "Failed to clear stale bank sync failure notes for user #{user&.id}: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
  end

  private_class_method
  def self.postal_code_invalid_error?(error)
    error.is_a?(Stripe::InvalidRequestError) && error.respond_to?(:code) && error.code == "postal_code_invalid"
  end

  # For Japanese accounts Stripe validates the kanji/kana address against its JP postal
  # directory and rejects mismatches (e.g. street details typed into the town field, or a
  # town that doesn't exist under the given postal code) with an InvalidRequestError like
  # `Invalid address for Japan. We cannot find an address with town of X for postal_code Y.`
  # We don't have that directory to pre-validate against, so these are expected seller-input
  # errors: the seller sees Stripe's message inline on the payments settings page and can
  # correct the address themselves. Stripe doesn't populate `code` on this rejection, so
  # match on the message.
  private_class_method
  def self.jp_address_invalid_error?(error)
    return false unless error.is_a?(Stripe::InvalidRequestError)

    error.message.to_s.match?(/invalid address for japan|cannot find an address with town of/i)
  end

  # Some countries have a habitual way of writing postal codes that differs from the exact
  # format Stripe's validation accepts. Stripe rejects the off-format code with
  # `postal_code_invalid`, and because merchant-account creation often runs asynchronously
  # after the settings save, that failure used to be invisible to the seller. Rewrite the
  # unambiguous habitual shapes into Stripe's expected format at the Stripe boundary:
  #
  # - Luxembourg: codes are four digits, but residents habitually add the conventional
  #   "L-" prefix (e.g. "L-9767"). Stripe only accepts the bare digits.
  # - Netherlands: codes are four digits + two letters, and Stripe requires the standard
  #   spaced uppercase form "NNNN LL" (e.g. "2742 NZ"), but sellers often type them without
  #   the space or in lowercase ("2742nz").
  #
  # Anything that doesn't match the expected shape passes through unchanged so Stripe can
  # report its own validation error rather than us guessing. Normalizing here (rather than
  # at input time) also repairs already-saved compliance records when the retry job
  # re-attempts account creation — no re-entry needed from the seller.
  private_class_method
  def self.normalize_postal_code(postal_code, country_code)
    return postal_code if postal_code.blank?

    case country_code
    when Compliance::Countries::LUX.alpha2
      normalized = postal_code.to_s.strip[/\AL[-\s]?(\d{4})\z/i, 1]
      return normalized if normalized.present?
    when Compliance::Countries::NLD.alpha2
      match = postal_code.to_s.strip.match(/\A(\d{4})\s?([A-Za-z]{2})\z/)
      return "#{match[1]} #{match[2].upcase}" if match
    end

    postal_code
  end

  # Stripe validates the tax IDs we pass on account creation (individual `id_number`,
  # business `tax_id`) and rejects obviously-fake values with an InvalidRequestError like
  # `Invalid Tax ID. 123456789 is not an allowed value.` — placeholder numbers (all-same
  # digits, sequential digits) are on Stripe's denylist. We don't pre-validate against that
  # denylist, so these are expected seller-input errors: the seller sees Stripe's message
  # inline on the payments settings page and can correct the tax ID themselves. Stripe
  # doesn't always populate `code`/`param` on this rejection, so also match on the message.
  private_class_method
  def self.tax_id_invalid_error?(error)
    return false unless error.is_a?(Stripe::InvalidRequestError)

    code = error.respond_to?(:code) ? error.code : nil
    return true if code == "tax_id_invalid"

    param = error.respond_to?(:param) ? error.param.to_s : ""
    return true if param.split("[").last.to_s.delete("]").in?(%w[id_number tax_id])

    error.message.to_s.match?(/invalid tax id/i)
  end

  # Stripe validates the phone numbers we pass on account creation (individual phone,
  # business support phone) and rejects malformed ones with an InvalidRequestError like
  # `"+9203661015" is not a valid phone number`. The client-side formatter only normalizes
  # to E.164 — it doesn't verify the number is real — so these are expected seller-input
  # errors: the seller sees Stripe's message inline on the payments settings page and can
  # correct the number themselves. Stripe doesn't always populate `code`/`param` on this
  # rejection, so match on the message.
  private_class_method
  def self.phone_number_invalid_error?(error)
    return false unless error.is_a?(Stripe::InvalidRequestError)

    param = error.respond_to?(:param) ? error.param.to_s : ""
    return true if param.split("[").last.to_s.delete("]").in?(%w[phone support_phone])

    error.message.to_s.match?(/is not a valid phone number/i)
  end

  private_class_method
  def self.bank_account_invalid_error?(error)
    return true if error.is_a?(Stripe::CardError)
    return false unless error.is_a?(Stripe::InvalidRequestError)

    code = error.respond_to?(:code) ? error.code : nil
    return false if code == "incorrect_account_holder_name"
    return true if %w[routing_number_invalid account_number_invalid].include?(code)

    param = error.respond_to?(:param) ? error.param.to_s : ""
    return true if param.start_with?("bank_account", "external_account")

    # A block-listed external account is a rejection of the seller's bank details in the sense
    # that matters here — only the seller can resolve it, by using a different account — and it
    # is returned indefinitely for the same input, so paging Sentry on every attempt is pure
    # noise. It is matched explicitly because the error does not reliably carry a code or param
    # (gumroad-private#1476).
    return true if bank_account_blocked?(error)

    # Stripe rejects some bank accounts with "Stripe is unable to support this bank at this
    # time." and populates neither `code` nor `param` on the error, so the checks above miss
    # it. It is still a rejection of the seller's bank details (a bank outside Stripe's payout
    # coverage), which the seller sees inline on the payments settings page and can only fix
    # by entering a different bank account — so treat it like the other bank rejections
    # (payout-note breadcrumb, no Sentry alert) instead of paging on every attempt.
    error.message.to_s.match?(/unable to support this bank/i)
  end

  private_class_method
  def self.record_postal_code_failure_note(user, error)
    code = error.respond_to?(:code) ? error.code : nil
    user.add_payout_note(
      content: "#{POSTAL_CODE_FAILURE_NOTE_PREFIX}: #{code || 'unknown'} — #{error.message.to_s.truncate(200)}",
      seller_visible: false
    )
  rescue => e
    Rails.logger.error "Failed to record postal-code payout-note breadcrumb for user #{user&.id}: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
  end

  # Leave a private breadcrumb naming exactly which field Stripe rejected when payout setup
  # fails for a reason we do not handle specifically.
  #
  # Why this exists: when Stripe refuses to create or update a connected account, the caller
  # (UpdateUserComplianceInfo) shows the seller Stripe's message and rolls the half-built
  # merchant account back. Nothing about the rejection was kept, so a seller stuck in this
  # state was undiagnosable from support tooling — the only evidence was a row created and
  # soft-deleted in the same second, with no error code and no indication of which field was
  # at fault. Support then has to guess, and the seller's own description of the error is
  # usually a paraphrase that points at the wrong field.
  #
  # Stripe puts the useful part in `code` and `param` rather than the message, so both are
  # recorded. `param` is the field name Stripe objected to; that single value is normally
  # enough to identify the problem without reproducing the failure.
  #
  # Seller-visible, so a seller who navigates away from the inline error still has a way to find
  # out. It carries our own wording rather than the raw parameter path: these rejections are not
  # auto-retryable (RetryStripeRejectedPayoutSetupsJob only picks up the postal-code and bank-sync
  # prefixes), so the seller has to act, and previously the one durable record was support-only.
  def self.record_account_rejection_note(user, error)
    return if user.blank?

    code = error.respond_to?(:code) ? error.code : nil
    param = error.respond_to?(:param) ? error.param : nil
    details = ["code=#{code || 'unknown'}"]
    details << "param=#{param}" if param.present?

    user.add_payout_note(
      content: "#{ACCOUNT_REJECTION_NOTE_PREFIX}: #{details.join(' ')} — #{error.message.to_s.truncate(300)}",
      seller_visible: false
    )

    # payout_setup_rejection_seller_message returns nil for bank-account rejections, which have
    # their own dedicated seller messaging elsewhere — writing a note with nil content would fail
    # Comment's presence validation and reach ErrorNotifier on every one of them.
    seller_message = payout_setup_rejection_seller_message(error, user)
    return if seller_message.blank?

    user.add_payout_note(
      content: seller_message,
      seller_visible: true,
      json_data: {
        PAYOUT_SETUP_REJECTION_NOTE_FLAG => true,
        PAYOUT_SETUP_REJECTED_FIELD_KEY => stripe_rejected_field(error),
      }
    )
  rescue => e
    # A missing breadcrumb must never turn into a second failure on top of the original
    # rejection: the seller's error message matters more than our diagnostics.
    Rails.logger.error "Failed to record Stripe account-rejection payout-note breadcrumb for user #{user&.id}: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
  end

  private_class_method
  def self.clear_stale_postal_code_failure_notes(user)
    user.comments
        .with_type_payout_note
        .alive
        .where(author_id: GUMROAD_ADMIN_ID)
        .where("content LIKE ?", "#{POSTAL_CODE_FAILURE_NOTE_PREFIX}%")
        .update_all(deleted_at: Time.current)
  rescue => e
    Rails.logger.error "Failed to clear stale postal-code failure notes for user #{user&.id}: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
  end

  # Deletes the marked seller-visible rejection note once the payout setup it describes has gone
  # through, so `Link#publish_blocked_message` and `User#latest_payout_setup_rejection_note` stop
  # finding it. json_data is a serialized text column MySQL cannot filter on directly (same
  # constraint as the LIKE prefilter above), so the flag is narrowed with a LIKE on its serialized
  # form before the in-memory check that actually reads it.
  #
  # `resolved_fields: :all` clears every marked note regardless of which field it named — correct
  # only at account creation, where there is no prior submission to have been partial. Other
  # callers pass the fields they actually sent, so a note whose rejection named a specific field
  # stays until that field is resubmitted and accepted, rather than being wiped by an unrelated
  # accepted field. A note with no recorded field (undiagnosed rejections with no Stripe `param`,
  # and notes written before this field was tracked) has nothing to scope to, so any success still
  # clears it — that was the only behavior before this fix.
  private_class_method
  def self.clear_stale_payout_setup_rejection_notes(user, resolved_fields: :all)
    user.comments
        .with_type_payout_note
        .alive
        .where(author_id: GUMROAD_ADMIN_ID)
        .where("json_data LIKE ?", "%#{PAYOUT_SETUP_REJECTION_NOTE_FLAG}%")
        .select { |note| note.json_data[PAYOUT_SETUP_REJECTION_NOTE_FLAG] == true }
        .select do |note|
          rejected_field = note.json_data[PAYOUT_SETUP_REJECTED_FIELD_KEY]
          resolved_fields == :all || rejected_field.nil? || resolved_fields.include?(rejected_field)
        end
        .each { |note| note.update!(deleted_at: Time.current) }
  rescue => e
    Rails.logger.error "Failed to clear stale payout-setup-rejection notes for user #{user&.id}: #{e.class}: #{e.message}"
    ErrorNotifier.notify(e)
  end

  def self.disconnect(user:)
    return false unless user.stripe_disconnect_allowed?

    user.stripe_connect_account.delete_charge_processor_account!
    user.check_merchant_account_is_linked = false
    user.save!

    # We deleted creator's gumroad-controlled Stripe account when they connected their own Stripe account.
    # Ref: User::OmniauthCallbacksController#stripe_connect.
    # Now when they are disconnecting their own Stripe account, we try and reactivate their old gumroad-controlled Stripe account.
    # Their old Stripe account is the one associated with any unpaid balance, or with their active bank account
    # as we didn't delete the active bank account when they connected their own Stripe account.
    stripe_account = user.merchant_accounts.stripe.where(id: user.unpaid_balances.pluck(:merchant_account_id).uniq).last
    stripe_account ||= user.merchant_accounts.stripe.where(charge_processor_merchant_id: user.active_bank_account&.stripe_connect_account_id).last
    return true if stripe_account.blank? || stripe_account.charge_processor_merchant_id.blank?
    stripe_account.deleted_at = stripe_account.charge_processor_deleted_at = nil
    stripe_account.charge_processor_alive_at = Time.current
    stripe_account.save!
  end

  private_class_method
  def self.save_stripe_bank_account_info(bank_account, stripe_account)
    # We replace the bank account whenever adding a new one, so there will only be one in the list.
    stripe_external_account = stripe_account.external_accounts.first
    bank_account.stripe_connect_account_id = stripe_account.id
    bank_account.stripe_external_account_id = stripe_external_account.id
    bank_account.stripe_fingerprint = stripe_external_account.fingerprint
    bank_account.save!(validate: false)

    CheckPaymentAddressWorker.perform_async(bank_account.user_id)
  end

  private_class_method
  def self.validate_for_update(user)
    unless user.stripe_account
      raise MerchantRegistrationUserNotReadyError
        .new(user.id, "does not have a Stripe merchant account")
    end
  end

  def self.cleanup_failed_merchant_account(merchant_account)
    if merchant_account.charge_processor_merchant_id.present?
      begin
        Stripe::Account.delete(merchant_account.charge_processor_merchant_id)
      rescue Stripe::StripeError => cleanup_error
        ErrorNotifier.notify(cleanup_error)
      end
    end
    merchant_account.mark_deleted!
  end

  def self.blocks_new_managed_account?(user)
    user.merchant_accounts.alive.stripe.any? do |ma|
      # Connect is a different path — create_account has always ignored it.
      # Check first: a live Connect row is charge_processor_alive?.
      next if ma.is_a_stripe_connect_account?
      next true if ma.charge_processor_alive?

      ma.charge_processor_merchant_id.present? || ma.created_at > STALE_HOLLOW_ACCOUNT_AGE.ago
    end
  end

  def self.discard_stale_hollow_managed_accounts!(user)
    user.merchant_accounts.alive.stripe.each do |ma|
      next if ma.is_a_stripe_connect_account?
      next if ma.charge_processor_alive?
      next if ma.charge_processor_merchant_id.present?
      next if ma.created_at > STALE_HOLLOW_ACCOUNT_AGE.ago

      cleanup_failed_merchant_account(ma)
    end
  end
  private_class_method :discard_stale_hollow_managed_accounts!

  # Strongbox decrypts (account number, tax ids) return ASCII-8BIT (binary) strings. When the
  # Stripe gem serializes the params it concatenates them with the other UTF-8 fields; if a
  # compliance field carries non-ASCII bytes (e.g. an umlaut/accent in a business name or address:
  # "Häuserhelden", "Düsseldorf"), Ruby raises Encoding::CompatibilityError ("incompatible character
  # encodings: UTF-8 and BINARY (ASCII-8BIT)") and the Stripe::Account.create/create_person call
  # never reaches Stripe — silently blocking the seller from getting a merchant account (gh-private
  # #683). IBANs and tax ids are pure-ASCII bytes, so relabeling them UTF-8 is lossless. Recursively
  # re-encode every ASCII-8BIT string in the params to UTF-8 right before the Stripe API call.
  def self.force_utf8_encoding(value)
    case value
    when Hash
      value.transform_values { |v| force_utf8_encoding(v) }
    when Array
      value.map { |v| force_utf8_encoding(v) }
    when String
      value.encoding == Encoding::ASCII_8BIT ? value.dup.force_encoding(Encoding::UTF_8) : value
    else
      value
    end
  end

  private_class_method
  def self.user_has_stripe_connect_merchant_account?(user)
    # It's really important we don't have two merchant accounts per user, so we do this check on the master database
    # to ensure we're looking at the latest data.
    ActiveRecord::Base.connection.stick_to_primary!
    user.stripe_account.present?
  end

  private_class_method
  def self.account_hash(user, tos_agreement, user_compliance_info, passphrase:)
    hash = {
      metadata: {
        user_id: user.external_id
      }
    }

    if tos_agreement
      tos_acceptance = {
        date: tos_agreement.created_at.to_time.to_i,
        ip: tos_agreement.ip
      }
      cross_border_payouts_only = Country.new(user_compliance_info.legal_entity_country_code).supports_stripe_cross_border_payouts?
      tos_acceptance[:service_agreement] = "recipient" if cross_border_payouts_only
      hash.deep_merge!(
        tos_acceptance:,
        metadata: {
          tos_agreement_id: tos_agreement.external_id
        }
      )
    end

    if user_compliance_info
      hash.deep_merge!(
        metadata: {
          user_compliance_info_id: user_compliance_info.external_id
        },
        business_type: if user_compliance_info.is_business?
                         if user_compliance_info.legal_entity_country_code == Compliance::Countries::CAN.alpha2 &&
                         %w(non_profit registered_charity).include?(user_compliance_info.business_type)
                           "non_profit"
                         else
                           "company"
                         end
                       else
                         "individual"
                       end,
        business_profile: {
          name: user_compliance_info.legal_entity_name,
          url: user.business_profile_url,
          product_description: user_compliance_info.legal_entity_name
        }
      )

      if [Compliance::Countries::ARE.alpha2, Compliance::Countries::CAN.alpha2].include?(user_compliance_info.country_code)
        hash[:business_profile][:support_phone] = user_compliance_info.business_phone
      end

      if user_compliance_info.is_business?
        hash.deep_merge!(company_hash(user_compliance_info, passphrase))
      else
        hash.deep_merge!(
          individual: person_hash(user_compliance_info, passphrase)
        )
      end
    end

    hash.deep_values_strip!
  end

  private_class_method
  def self.bank_account_hash(bank_account, stripe_account: {}, passphrase:)
    country_code = bank_account.user.alive_user_compliance_info.legal_entity_country_code
    cross_border_payouts_only = Country.new(country_code).supports_stripe_cross_border_payouts?

    bank_account_field =
      if bank_account.is_a?(CardBankAccount)
        Stripe::Token.create({ customer: bank_account.credit_card.stripe_customer_id }, { stripe_account: stripe_account["id"] }).id
      else
        account_number_for_stripe =
          if bank_account.respond_to?(:stripe_account_number)
            bank_account.stripe_account_number(passphrase)
          else
            bank_account.account_number.decrypt(passphrase).gsub(/[ -]/, "")
          end
        bank_account_hash = {
          country: bank_account.stripe_external_account_country,
          currency: bank_account.stripe_external_account_currency,
          account_number: account_number_for_stripe
        }
        routing_number = bank_account.stripe_external_account_routing_number
        if routing_number.present?
          routing_number = routing_number.gsub(/[ -]/, "") if country_code == Compliance::Countries::GIB.alpha2
          bank_account_hash[:routing_number] = routing_number
        end
        bank_account_hash[:account_type] = bank_account.account_type if [Compliance::Countries::CHL.alpha2, Compliance::Countries::COL.alpha2].include?(country_code) && bank_account.account_type.present?
        bank_account_hash[:account_holder_name] = bank_account.account_holder_full_name if account_holder_name_synced_to_stripe?(bank_account.user)
        bank_account_hash
      end

    settings = {
      payouts: {
        schedule: {
          interval: "manual"
        },
        debit_negative_balances: !cross_border_payouts_only
      }
    }

    metadata = stripe_account["metadata"].to_h || {}
    metadata[:bank_account_id] = bank_account.external_id

    attributes = {
      metadata:,
      # TODO replace `bank_account` with `external_account` (https://stripe.com/docs/upgrades#2015-10-01)
      # The `bank_account` is a deprecated field that continues to be supported, but the docs say it should
      # be renamed to `external_account`. Renaming the field causes a problem when calling `update_bank_account`
      # ("Cannot save property `external_account` containing an API resource. It doesn't appear to be persisted and is not marked as `save_with_parent`.")
      # Everything works well during account creation. Seems to be an issue with stripe ruby gem.
      bank_account: bank_account_field,
      settings:
    }
    attributes.deep_values_strip!
  end

  private_class_method
  def self.person_hash(user_compliance_info, passphrase)
    if user_compliance_info
      personal_tax_id = user_compliance_info.individual_tax_id.decrypt(passphrase)
      country_code = user_compliance_info.country_code

      hash = {
        first_name: user_compliance_info.first_name,
        last_name: user_compliance_info.last_name,
        email: user_compliance_info.user.email,
        phone: user_compliance_info.phone,

        dob: {
          day: user_compliance_info.birthday.try(:day),
          month: user_compliance_info.birthday.try(:month),
          year: user_compliance_info.birthday.try(:year)
        }
      }

      if user_compliance_info.country_code == Compliance::Countries::JPN.alpha2
        address_kanji = {
          line1: user_compliance_info.building_number,
          town: user_compliance_info.street_address_kanji,
          state: user_compliance_info.state,
          country: "JP",
          postal_code: user_compliance_info.zip_code
        }
        address_kana = {
          line1: user_compliance_info.building_number_kana,
          town: user_compliance_info.street_address_kana,
          state: prefecture_kana(user_compliance_info.state),
          country: "JP",
          postal_code: user_compliance_info.zip_code
        }
        # Compliance records saved before the dedicated Japanese city fields existed have no city
        # value. Stripe rejects an address update that includes an explicit null city, so only add
        # the key when the seller has actually provided one.
        address_kanji[:city] = user_compliance_info.city if user_compliance_info.city.present?
        address_kana[:city] = user_compliance_info.city_kana if user_compliance_info.city_kana.present?
        hash.deep_merge!({
                           first_name_kanji: user_compliance_info.first_name_kanji,
                           last_name_kanji: user_compliance_info.last_name_kanji,
                           first_name_kana: user_compliance_info.first_name_kana,
                           last_name_kana: user_compliance_info.last_name_kana,
                           address_kanji:,
                           address_kana:
                         })
      else
        hash.deep_merge!({
                           address: {
                             line1: user_compliance_info.street_address,
                             line2: nil,
                             city: user_compliance_info.city,
                             state: user_compliance_info.state,
                             postal_code: normalize_postal_code(user_compliance_info.zip_code, country_code),
                             country: country_code
                           },
                         })
      end

      # `id_number` / `ssn_last_4` are validated by Stripe against the *account* country, not the
      # representative's. For a US account Stripe expects a 9-digit SSN/ITIN. Submitting a foreign
      # national ID (e.g. a 10-digit Bangladeshi NID for a foreign-resident US-LLC owner) trips a
      # "must be 9 digits" rejection. In that case we omit the tax ID so Stripe falls through to the
      # standard document-verification remediation flow.
      legal_entity_country_code = user_compliance_info.legal_entity_country_code
      if personal_tax_id.present?
        if legal_entity_country_code == Compliance::Countries::USA.alpha2
          if country_code == Compliance::Countries::USA.alpha2 && personal_tax_id.length == 4
            hash.deep_merge!(ssn_last_4: personal_tax_id.last(4))
          elsif personal_tax_id.length == 9
            hash.deep_merge!(id_number: personal_tax_id)
          end
        else
          hash.deep_merge!(id_number: personal_tax_id)
        end
      end

      if [Compliance::Countries::ARE.alpha2,
          Compliance::Countries::SGP.alpha2,
          Compliance::Countries::BGD.alpha2,
          Compliance::Countries::PAK.alpha2].include?(legal_entity_country_code)
        hash.deep_merge!(nationality: user_compliance_info.nationality)
      end

      hash.deep_values_strip!
    end
  end

  def self.company_hash(user_compliance_info, passphrase)
    return unless user_compliance_info.present?

    business_tax_id = user_compliance_info.business_tax_id.decrypt(passphrase)
    hash = {
      company: {
        name: user_compliance_info.business_name.presence,
        address: {
          line1: user_compliance_info.legal_entity_street_address,
          line2: nil,
          city: user_compliance_info.legal_entity_city,
          state: user_compliance_info.legal_entity_state,
          postal_code: normalize_postal_code(user_compliance_info.legal_entity_zip_code, user_compliance_info.legal_entity_country_code),
          country: user_compliance_info.legal_entity_country_code
        },
        tax_id: business_tax_id.presence,
        phone: user_compliance_info.business_phone,
        directors_provided: true,
        executives_provided: true,
      }
    }

    if user_compliance_info.country_code == Compliance::Countries::JPN.alpha2
      business_address_kanji = {
        line1: user_compliance_info.business_building_number,
        town: user_compliance_info.business_street_address_kanji,
        state: user_compliance_info.business_state,
        country: "JP",
        postal_code: user_compliance_info.legal_entity_zip_code
      }
      business_address_kana = {
        line1: user_compliance_info.business_building_number_kana,
        town: user_compliance_info.business_street_address_kana,
        state: prefecture_kana(user_compliance_info.business_state),
        country: "JP",
        postal_code: user_compliance_info.legal_entity_zip_code
      }
      # Compliance records saved before the dedicated Japanese city fields existed have no city
      # value. Stripe rejects an address update that includes an explicit null city, so only add
      # the key when the seller has actually provided one.
      business_address_kanji[:city] = user_compliance_info.business_city if user_compliance_info.business_city.present?
      business_address_kana[:city] = user_compliance_info.business_city_kana if user_compliance_info.business_city_kana.present?
      hash.deep_merge!({
                         company: {
                           name_kanji: user_compliance_info.business_name_kanji,
                           name_kana: user_compliance_info.business_name_kana,
                           address_kanji: business_address_kanji,
                           address_kana: business_address_kana
                         }
                       })
    end

    if user_compliance_info.country_code == Compliance::Countries::ARE.alpha2
      hash.deep_merge!(
        company: {
          structure: user_compliance_info.business_type,
          vat_id: user_compliance_info.business_vat_id_number
        }
      )
    elsif user_compliance_info.legal_entity_country_code == Compliance::Countries::CAN.alpha2
      hash.deep_merge!(
        company: {
          structure: user_compliance_info.business_type == "non_profit" ? "" : user_compliance_info.business_type,
        }
      )
    elsif user_compliance_info.country_code == Compliance::Countries::USA.alpha2 && user_compliance_info.business_type == UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP
      hash[:company][:structure] = user_compliance_info.business_type
    end

    hash
  end

  def self.handle_stripe_event(stripe_event)
    case stripe_event["type"]
    when "account.updated"
      handle_stripe_event_account_updated(stripe_event)
    when "account.application.deauthorized"
      handle_stripe_event_account_deauthorized(stripe_event)
    when "capability.updated"
      handle_stripe_event_capability_updated(stripe_event)
    end
  end

  def self.handle_stripe_event_account_deauthorized(stripe_event)
    stripe_event_id = stripe_event["id"]
    stripe_account = stripe_event["data"] && stripe_event["data"]["object"]
    raise "Stripe Event #{stripe_event_id} does not contain an 'account' object." if stripe_event["type"] != "account.application.deauthorized" && (stripe_account && stripe_account["object"]) != "account"

    stripe_account_id = if stripe_event["type"] == "account.application.deauthorized"
      stripe_event["user_id"].present? ? stripe_event["user_id"] : stripe_event["account"]
    else
      stripe_account["id"]
    end

    merchant_account = MerchantAccount.where(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             charge_processor_merchant_id: stripe_account_id).alive.last

    return if merchant_account.nil?

    merchant_account.delete_charge_processor_account!

    user = merchant_account.user

    if user.merchant_migration_enabled?
      MerchantRegistrationMailer.account_deauthorized_to_user(
        user.id,
        StripeChargeProcessor.charge_processor_id
      ).deliver_later(queue: "critical")
    end
  end

  def self.handle_stripe_event_capability_updated(stripe_event)
    stripe_event_id = stripe_event["id"]
    stripe_capability = stripe_event["data"]["object"]
    stripe_previous_attributes = stripe_event["data"]["previous_attributes"] || {}
    raise "Stripe Event #{stripe_event_id} does not contain a 'capability' object." if stripe_capability["object"] != "capability"

    stripe_account_id = stripe_capability["account"]
    merchant_account = MerchantAccount.where(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             charge_processor_merchant_id: stripe_account_id)
                                      .alive.charge_processor_alive.last
    refresh_payment_method_availability(merchant_account)
    return unless merchant_account&.country == Compliance::Countries::JPN.alpha2

    stripe_account = Stripe::Account.retrieve(stripe_account_id)
    handle_stripe_info_requirements(stripe_event_id, stripe_account, stripe_previous_attributes)
  end

  def self.handle_stripe_event_account_updated(stripe_event)
    stripe_event_id = stripe_event["id"]
    stripe_account = stripe_event["data"]["object"]
    stripe_previous_attributes = stripe_event["data"]["previous_attributes"] || {}
    raise "Stripe Event #{stripe_event_id} does not contain an 'account' object." if stripe_account["object"] != "account"
    merchant_account = MerchantAccount.where(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             charge_processor_merchant_id: stripe_account["id"]).alive.charge_processor_alive.last
    refresh_payment_method_availability(merchant_account)
    clear_settlement_currency_mismatch_on_currency_change(merchant_account, stripe_previous_attributes)
    handle_stripe_info_requirements(stripe_event_id, stripe_account, stripe_previous_attributes)
  end

  # Buyer-currency checkout learns that an account settles in a non-USD currency (Stripe
  # multi-currency settlement) from a rejected FX quote and records it on the merchant
  # account so later checkouts skip the doomed quote call (issue #6011). Settlement
  # behavior is driven by the account's currency configuration — default_currency and the
  # set of external accounts (bank accounts) determine which currencies the account can
  # settle in — so when account.updated says either changed, forget the learned marker and
  # let the next eligible checkout probe Stripe again. Clearing is cheap and safe: the
  # worst case is one extra FX-quote round trip that re-records the mismatch.
  def self.clear_settlement_currency_mismatch_on_currency_change(merchant_account, stripe_previous_attributes)
    return if merchant_account.nil?

    # In production the webhook handler passes a Stripe::StripeObject here, not a Hash, and
    # StripeObject (stripe-ruby 12.x) does not respond to `key?` — calling it raised a
    # NoMethodError on every account.updated event and left learned mismatch markers
    # permanently uncleared (gumroad-private#933, 2026-07-20). Normalize to a Hash first;
    # StripeObject#to_hash yields symbol keys while raw webhook payloads use string keys, so
    # check both.
    previous_attributes = stripe_previous_attributes.respond_to?(:to_hash) ? stripe_previous_attributes.to_hash : stripe_previous_attributes
    currency_config_changed = %w[default_currency external_accounts].any? do |attribute|
      previous_attributes.key?(attribute) || previous_attributes.key?(attribute.to_sym)
    end
    return unless currency_config_changed

    merchant_account.clear_settlement_currency_mismatch!
  rescue StandardError => e
    # The rest of the account.updated handling (payment method availability, compliance
    # info requirements) must not be skipped because this bookkeeping failed.
    Rails.logger.warn("Failed to clear settlement currency mismatch for merchant account #{merchant_account.id}: #{e.class} #{e.message}")
  end

  # A capability or account change on a Stripe Connect (direct-charge) account may mean the
  # seller (de)activated Cash App Pay or ACH in their own Stripe dashboard, which changes what
  # checkout may offer on their account (see Checkout::PaymentMethodResolver). Refresh the
  # cached availability snapshot in the background. This must run BEFORE the early returns
  # below/around it: the JP-only guard and the standard-account guard in
  # handle_stripe_info_requirements would otherwise skip connect accounts entirely — and connect
  # accounts are exactly the population this cache is for.
  def self.refresh_payment_method_availability(merchant_account)
    return unless merchant_account&.is_a_stripe_connect_account?

    RefreshMerchantAccountPaymentMethodAvailabilityWorker.perform_async(merchant_account.id)
  end

  def self.handle_stripe_info_requirements(stripe_event_id, stripe_account, stripe_previous_attributes)
    return if stripe_account["type"] == "standard"

    stripe_account_id = stripe_account["id"]

    merchant_account = MerchantAccount.where(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                             charge_processor_merchant_id: stripe_account_id).last
    raise "No Merchant Account for Stripe Account ID #{stripe_account_id}" if merchant_account.nil?

    return unless merchant_account.alive?

    unless merchant_account.charge_processor_alive?
      Rails.logger.info "Merchant account #{merchant_account.id} not marked as alive in Stripe, ignoring event #{stripe_event_id}"
      return
    end

    user = merchant_account.user

    return unless user.account_active?

    requirements = stripe_account["requirements"] || {}
    future_requirements = stripe_account["future_requirements"] || {}

    should_save = false
    if stripe_account["default_currency"] && stripe_account["country"]
      merchant_account.currency = stripe_account["default_currency"]
      merchant_account.country = stripe_account["country"]
      should_save = true
    end
    if merchant_account.stripe_disabled_reason != requirements["disabled_reason"]
      merchant_account.stripe_disabled_reason = requirements["disabled_reason"]
      should_save = true
    end
    merchant_account.save! if should_save

    # A `rejected.*` disabled_reason is usually terminal, but not always: Stripe
    # sometimes marks an account rejected while still keeping an identity
    # document request open (seen with Japan `rejected.listed` collisions).
    # Those sellers can still verify and be reinstated, so only treat the
    # rejection as final when Stripe is asking for nothing more — otherwise we
    # would close the very verification request the seller needs and tell them
    # the rejection cannot be appealed while Stripe is mid-appeal.
    # The terminal handling itself (closing requests + the one-time rejection
    # email) runs further down, AFTER the payouts-pause sync: the rejection
    # email's copy depends on whether Stripe froze payouts, so the pause state
    # from this same webhook must be committed before the email is enqueued.
    account_terminally_rejected = merchant_account.stripe_rejected? &&
      stripe_requirements_exhausted?(requirements, future_requirements)

    individual = if stripe_account["business_type"] == "individual"
      stripe_account["individual"] || {}
    else
      person = Stripe::Account.list_persons(stripe_account_id, { limit: 1 }).first
      if person && person["relationship"] && person["relationship"]["representative"] == false
        person = Stripe::Account.list_persons(stripe_account_id, relationship: { representative: true }, limit: 1).first
      end
      person || {}
    end
    individual_verification_status = individual["verification"].try(:[], "status")
    merchant_account.mark_charge_processor_verified! if individual_verification_status == "verified"
    merchant_account.mark_charge_processor_unverified! if individual_verification_status == "unverified"

    deadline = if requirements["current_deadline"].present? && future_requirements["current_deadline"].present?
      [requirements["current_deadline"], future_requirements["current_deadline"]].min
    else
      requirements["current_deadline"].presence || future_requirements["current_deadline"]
    end
    requirements_due_at = Time.zone.at(deadline) if deadline.present?

    alternative_requirements = requirements["alternatives"]&.map { _1["alternative_fields_due"] } || []
    alternative_future_requirements = future_requirements["alternatives"]&.map { _1["alternative_fields_due"] } || []
    alternative_fields_due = (alternative_requirements + alternative_future_requirements).compact.reduce([], :+).uniq

    # future_requirements["eventually_due"] contains fields that will be needed sometime in the future,
    # we don't need to collect those currently. E.g. Full 9-digit SSN is required for a US account once it
    # $500k in payments, but Stripe shows that field under future_requirements["eventually_due"] for all US accounts.
    stripe_fields_needed = [requirements["currently_due"], requirements["eventually_due"], requirements["past_due"],
                            future_requirements["currently_due"], future_requirements["past_due"], alternative_fields_due].compact.reduce([], :+).uniq
    stripe_fields_needed.map! do |stripe_field_needed|
      # Example identity-related missing field for individual account: `individual.dob.day`
      # Example identity-related missing field for business account: `person_IRWHQ2ZRlwIh1j.dob.day`
      # Here we convert the `person_IRWHQ2ZRlwIh1j.dob.day` => `individual.dob.day` before using it as a lookup key
      stripe_field_needed.gsub(/^person_\w+\./, "individual.")
    end

    fields_needed = []
    verification_errors = {}
    stripe_risk_fields_needed = []

    stripe_fields_needed.each do |stripe_field_needed|
      field_needed = StripeUserComplianceInfoFieldMap.map(stripe_field_needed).presence || stripe_field_needed
      if stripe_field_needed.match?(/^interv_/)
        stripe_risk_fields_needed << stripe_field_needed
      else
        field_options = StripeUserComplianceInfoFieldMap.options_for_field(stripe_field_needed)
        fields_needed << [field_needed, field_options]
        field_error = requirements["errors"].find { |error| error["requirement"] == stripe_field_needed } if requirements["errors"].present?
        field_error ||= future_requirements["errors"].find { |error| error["requirement"] == stripe_field_needed } if future_requirements["errors"].present?
        verification_errors[field_needed] = { code: field_error["code"], reason: field_error["reason"] } if field_error.present?
      end
    end

    user.user_compliance_info_requests.requested.find_each do |user_compliance_info|
      still_needed = fields_needed.map { |name_and_options| name_and_options[0] }.include?(user_compliance_info.field_needed)
      still_needed ||= stripe_risk_fields_needed.include?(user_compliance_info.field_needed)
      user_compliance_info.mark_provided! unless still_needed
    end

    new_risk_requirement_added = false
    stripe_risk_fields_needed.each do |stripe_risk_field_needed|
      next if user.user_compliance_info_requests.requested.where(field_needed: stripe_risk_field_needed).present?

      risk_requirement_category = stripe_risk_field_needed.split(".")[1]

      if APPEAL_INTERVENTION_CATEGORIES.include?(risk_requirement_category)
        # Account not supportable under Stripe supportability.
        # Suspend the account and inform the creator via email.
        user.suspend_due_to_stripe_risk(disabled_reason: requirements["disabled_reason"])
      elsif account_terminally_rejected
        # Stripe has permanently rejected the account and is asking for nothing
        # more, so there is nothing the seller can submit that would change the
        # outcome. Don't open a new verification request (which would trigger a
        # remediation email whose link dead-ends for rejected accounts). When a
        # rejected account DOES still have open requirements (the appealable
        # fork, e.g. Japan `rejected.listed` with a live document request), we
        # fall through and open the request so the seller keeps their
        # remediation path.
        next
      else
        # Some info/verification is required by Stripe for supportability.
        # Send a Stripe remediation link to the creator via email so they can submit the info.
        user_compliance_info_request = user.user_compliance_info_requests.build
        user_compliance_info_request.field_needed = stripe_risk_field_needed
        user_compliance_info_request.due_at = requirements_due_at
        user_compliance_info_request.stripe_event_id = stripe_event_id
        user_compliance_info_request.save!
        new_risk_requirement_added = true
      end
    end

    ContactingCreatorMailer.stripe_remediation(user.id).deliver_later if new_risk_requirement_added

    is_charges_disabled = !stripe_account["charges_enabled"]
    charges_newly_disabled = stripe_account["charges_enabled"] == false && stripe_previous_attributes["charges_enabled"] == true

    active_bank_account = user.active_bank_account
    if active_bank_account.is_a?(CardBankAccount)
      card_account_needs_syncing = active_bank_account.stripe_connect_account_id.blank?

      if is_charges_disabled
        # Ignore request for card bank account until charges become enabled
        fields_needed.delete_if { |field_needed| field_needed[0] == UserComplianceInfoFields::BANK_ACCOUNT }
      elsif card_account_needs_syncing
        result = update_bank_account(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        active_bank_account = user.active_bank_account
        if result == :stripe_unknown_error && active_bank_account
          HandleNewBankAccountWorker.perform_in(5.seconds, active_bank_account.id)
        end
        if active_bank_account&.stripe_connect_account_id.present?
          fields_needed.delete_if { |field_needed| field_needed[0] == UserComplianceInfoFields::BANK_ACCOUNT }
        end
      end
    end

    if charges_newly_disabled &&
      stripe_fields_needed.present? &&
      requirements["disabled_reason"].in?(%w(action_required.requested_capabilities requirements.past_due))
      MerchantRegistrationMailer.stripe_charges_disabled(user.id).deliver_later(queue: "critical")
    end

    action_required_fields_present = [requirements["currently_due"], requirements["past_due"],
                                      future_requirements["currently_due"], future_requirements["past_due"],
                                      alternative_fields_due].compact.flatten.any?
    pause_email_type = stripe_payouts_pause_email_type(requirements["disabled_reason"], action_required_fields_present)

    # Serialize concurrent account.updated webhooks for the same user so two
    # near-simultaneous events can't both pass the "not yet paused" check and
    # write duplicate comments / send duplicate emails. The email is enqueued
    # after the lock commits; the dedupe marker is claimed inside it.
    pause_email_to_send = nil
    user.with_lock do
      # Refresh under the lock so the dedupe marker reflects commits from any
      # concurrent webhook that ran just before us (with_lock reloads the user,
      # but not merchant_account, where the marker lives).
      merchant_account.reload
      if stripe_account["payouts_enabled"] && user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE
        user.update!(payouts_paused_internally: false, payouts_paused_by: nil)
        user.comments.create!(
          author_name: STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR,
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED,
          content: user.payouts_paused_by_user? ?
            "Stripe re-enabled payouts on the connected account; payouts remain paused by the creator." :
            "Payouts automatically resumed: Stripe re-enabled payouts on the connected account."
        )
        merchant_account.update!(stripe_payouts_pause_email_sent: nil, stripe_payouts_pause_email_claim_token: nil) if merchant_account.stripe_payouts_pause_email_sent
      elsif stripe_account["payouts_enabled"] == false && !user.payouts_paused_internally?
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
        user.comments.create!(
          author_name: STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR,
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
          content: merchant_account.stripe_payouts_paused_comment
        )
        pause_email_to_send = claim_stripe_payouts_pause_email(merchant_account, pause_email_type)
      elsif stripe_account["payouts_enabled"] == false && user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE
        refreshed_comment = merchant_account.stripe_payouts_paused_comment
        if user.comments.with_type_payouts_paused.last&.content != refreshed_comment
          user.comments.create!(
            author_name: STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR,
            comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
            content: refreshed_comment
          )
        end
        pause_email_to_send = claim_stripe_payouts_pause_email(merchant_account, pause_email_type)
      end
    end

    case pause_email_to_send
    when :action_required, :under_review
      # Don't email immediately: schedule a delayed job that re-checks the
      # account and only sends if payouts are still paused by Stripe, so a
      # verification blip that auto-resolves inside the window never emails.
      # The claim token ties the job to this specific pause episode.
      StripePayoutsPausedEmailJob.perform_in(
        PAYOUTS_PAUSE_EMAIL_DEBOUNCE_DELAY,
        user.id,
        merchant_account.id,
        pause_email_to_send.to_s,
        merchant_account.stripe_payouts_pause_email_claim_token
      )
    end

    # A terminally rejected account is final, so don't open new verification
    # requests or send "we need more information" emails — there is nothing
    # the seller can provide that would change Stripe's decision. This runs
    # after the payouts-pause sync above on purpose: the rejection email tells
    # the seller what happens to their balance, and that copy reads the pause
    # state this same webhook may have just written. Appealable rejections
    # (Stripe rejected the account but is still asking for something, e.g. an
    # identity document) fall through, so those sellers keep getting
    # verification requests and the emails that guide them.
    if account_terminally_rejected
      handle_stripe_rejection(user, merchant_account)
      return
    end

    last_outstanding_request_at = user.user_compliance_info_requests.requested.last&.created_at

    return if fields_needed.empty?

    new_requests = []
    fields_needed.each do |field_needed, options|
      only_needs_field_to_be_partially_provided = options[:only_needs_field_to_be_partially_provided]
      next if user.user_compliance_info_requests
                  .requested
                  .where(field_needed:)
                  .only_needs_field_to_be_partially_provided(only_needs_field_to_be_partially_provided)
                  .present?

      user_compliance_info_request = user.user_compliance_info_requests.build
      user_compliance_info_request.only_needs_field_to_be_partially_provided = only_needs_field_to_be_partially_provided
      user_compliance_info_request.field_needed = field_needed
      user_compliance_info_request.due_at = requirements_due_at
      user_compliance_info_request.stripe_event_id = stripe_event_id
      if verification_errors[field_needed].present?
        user_compliance_info_request.verification_error = verification_errors[field_needed]
      end
      user_compliance_info_request.save!
      new_requests << user_compliance_info_request
    end

    return if new_requests.blank? && last_outstanding_request_at.to_i > 1.month.ago.to_i

    all_fields_needed = user.user_compliance_info_requests.requested.where.not("field_needed like 'interv_%'").map(&:field_needed).uniq
    return if all_fields_needed.empty?

    document_verification_error = verification_errors.select { |_field, error| error[:code].starts_with?("verification_document") }.first
    skip_more_kyc_email = requirements_only_soft_future?(requirements, new_requests, all_fields_needed, requirements_due_at)
    email_sent = if document_verification_error.present?
      ContactingCreatorMailer.stripe_document_verification_failed(user.id, seller_facing_verification_reason(user, document_verification_error[1])).deliver_later(queue: "critical")
    elsif verification_errors.present?
      ContactingCreatorMailer.stripe_identity_verification_failed(user.id, seller_facing_verification_reason(user, verification_errors.first[1])).deliver_later(queue: "critical")
    elsif skip_more_kyc_email
      nil
    else
      ContactingCreatorMailer.more_kyc_needed(user.id, all_fields_needed).deliver_later(queue: "critical")
    end

    if email_sent
      email_sent_at = Time.current
      new_requests.each { |request| request.record_email_sent!(email_sent_at) }
    end
  end

  def self.prefecture_kana(kanji)
    Compliance::Countries.japan_prefecture_kana(kanji)
  end

  # Stripe's own rejection reason is what we normally forward to the seller, but for an
  # address-mismatch rejection on a seller whose registered address is a P.O. Box that reason is
  # actively wrong: it asks them to fix the address or upload a matching document, and neither is
  # possible (see UserComplianceInfoRequest for the full explanation of the deadlock). Send those
  # sellers to support instead of into another round of the same rejected upload.
  def self.seller_facing_verification_reason(user, verification_error)
    if UserComplianceInfoRequest.po_box_address_deadlock?(user:, error_code: verification_error[:code])
      return UserComplianceInfoRequest::PO_BOX_ADDRESS_DEADLOCK_MESSAGE
    end

    verification_error[:reason]
  end

  # Stripe has nothing further the seller could submit: no currently-due or
  # past-due requirements now, and none scheduled to become due. When a
  # rejected account still carries open requirements, the rejection is
  # appealable (the seller can upload the requested document and be
  # reinstated), so it must NOT be handled as terminal.
  #
  # `interv_*` entries mostly don't count as open requirements here. On a
  # rejected account Stripe leaves a permanent supportability intervention
  # (e.g. `interv_....other_supportability_inquiry.support`) in `currently_due`
  # and never clears it — there is no form the seller can fill in for it.
  # Treating it as an open requirement made every account rejected for
  # supportability look appealable forever: their verification requests stayed
  # open, the rejection email never went out, reminders kept firing, and the
  # balance release never applied.
  #
  # The exception is appeal-category interventions (`rejection_appeal`,
  # `supportability_rejection_appeal`): those mean the seller is inside an
  # active appeal window, so the rejection is not final yet. The webhook
  # handler suspends the seller pending the appeal — sending the "cannot be
  # appealed or reversed" rejection email on top of that would contradict the
  # appeal in progress. So concrete, fillable requirements (identity
  # documents, tax IDs, ...) AND appeal interventions keep a rejection
  # appealable; only permanent, non-actionable interventions are ignored.
  def self.stripe_requirements_exhausted?(requirements, future_requirements)
    [
      requirements["currently_due"],
      requirements["past_due"],
      requirements["eventually_due"],
      future_requirements["currently_due"],
    ].all? do |fields|
      (fields || []).all? do |field|
        field.start_with?("interv_") && !APPEAL_INTERVENTION_CATEGORIES.include?(field.split(".")[1])
      end
    end
  end

  # Runs on every account.updated webhook once Stripe has permanently rejected
  # the account. Closes any open verification requests — which stops both the
  # "payouts may be blocked" reminder loop and the remediation emails whose
  # links dead-end on rejected accounts — and sends the seller a single email
  # explaining that the rejection is final and what happens to their balance.
  def self.handle_stripe_rejection(user, merchant_account)
    user.user_compliance_info_requests.requested.find_each(&:mark_provided!)

    # Stripe can deliver (or retry) the same account.updated webhook while an
    # earlier job for this account is still running. Take a row lock before
    # checking the sent marker so only one job wins and the seller can never
    # receive the "account closed" email twice.
    send_email = false
    merchant_account.with_lock do
      unless merchant_account.stripe_rejection_email_sent
        merchant_account.update!(stripe_rejection_email_sent: true)
        send_email = true
      end
    end
    return unless send_email

    MerchantRegistrationMailer.stripe_account_rejected(user.id).deliver_later(queue: "critical")
  end

  def self.handle_new_user_compliance_info(user_compliance_info, notify: true, force_address_resync: false)
    return if user_compliance_info.user.has_stripe_account_connected?
    return unless user_has_stripe_connect_merchant_account?(user_compliance_info.user)

    update_account(user_compliance_info.user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"), notify:, force_address_resync:)
  end

  def self.handle_new_bank_account(bank_account)
    return if bank_account.user.has_stripe_account_connected?
    return unless user_has_stripe_connect_merchant_account?(bank_account.user)

    update_bank_account(bank_account.user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
  end

  SOFT_FUTURE_REQUIREMENT_GRACE_PERIOD = 30.days

  private_class_method
  def self.requirements_only_soft_future?(requirements, new_requests, all_fields_needed, requirements_due_at)
    return false if Array(all_fields_needed).empty?
    return false unless requirements_due_at.blank? || requirements_due_at > SOFT_FUTURE_REQUIREMENT_GRACE_PERIOD.from_now

    eventually_due_only = (requirements["eventually_due"] || []) -
                          (requirements["currently_due"] || []) -
                          (requirements["past_due"] || [])
    return false if eventually_due_only.empty?

    soft_field_names = eventually_due_only.map do |raw_field|
      normalized = raw_field.gsub(/^person_\w+\./, "individual.")
      StripeUserComplianceInfoFieldMap.map(normalized).presence || normalized
    end

    if new_requests.present?
      return false unless new_requests.all? { |request| soft_field_names.include?(request.field_needed) }
    end
    return false unless Array(all_fields_needed).all? { |field| soft_field_names.include?(field) }

    true
  end
end
