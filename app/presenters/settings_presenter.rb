# frozen_string_literal: true

class SettingsPresenter
  include CurrencyHelper
  include ActiveSupport::NumberHelper
  include Rails.application.routes.url_helpers

  attr_reader :pundit_user, :seller

  ALL_PAGES = %w(
    main
    team
    payments
    billing
    authorized_applications
    password
    third_party_analytics
    advanced
  ).freeze

  private_constant :ALL_PAGES

  def initialize(pundit_user:)
    @pundit_user = pundit_user
    @seller = pundit_user.seller
  end

  def pages
    @_pages ||= ALL_PAGES.select do |page|
      case page
      when "main", "payments", "password", "third_party_analytics", "advanced"
        Pundit.policy!(pundit_user, [:settings, page.to_sym, seller]).show?
      when "billing"
        Pundit.policy!(pundit_user, [:settings, page.to_sym]).show?
      when "team"
        Pundit.policy!(pundit_user, [:settings, :team, seller]).show?
      when "authorized_applications"
        Pundit.policy!(pundit_user, [:settings, :authorized_applications, OauthApplication]).index? &&
        OauthApplication.alive.authorized_for(seller).present?
      else
        raise StandardError, "Unsupported page `#{page}`"
      end
    end
  end

  def main_props
    {
      settings_pages: pages,
      is_form_disabled: !Pundit.policy!(pundit_user, [:settings, :main, seller]).update?,
      invalidate_active_sessions: Pundit.policy!(pundit_user, [:settings, :main, seller]).invalidate_active_sessions?,
      ios_app_store_url: IOS_APP_STORE_URL,
      android_app_store_url: ANDROID_APP_STORE_URL,
      timezones: ActiveSupport::TimeZone.all.map { |tz| { name: tz.name, offset: tz.formatted_offset } },
      currencies: currency_choices.map { |name, code| { name:, code: } },
      user: {
        email: seller.form_email,
        username: seller.read_attribute(:username).to_s,
        support_email: seller.support_email,
        locale: seller.locale,
        timezone: seller.timezone,
        currency_type: seller.currency_type,
        has_unconfirmed_email: seller.has_unconfirmed_email?,
        compliance_country: seller.alive_user_compliance_info&.country,
        purchasing_power_parity_enabled: seller.purchasing_power_parity_enabled?,
        purchasing_power_parity_limit: seller.purchasing_power_parity_limit,
        purchasing_power_parity_payment_verification_disabled: seller.purchasing_power_parity_payment_verification_disabled?,
        products: seller.products.visible.map { |product| { id: product.external_id, name: product.name } },
        purchasing_power_parity_excluded_product_ids: seller.purchasing_power_parity_excluded_product_external_ids,
        enable_payment_email: seller.enable_payment_email,
        enable_payment_push_notification: seller.enable_payment_push_notification,
        enable_recurring_subscription_charge_email: seller.enable_recurring_subscription_charge_email,
        enable_recurring_subscription_charge_push_notification: seller.enable_recurring_subscription_charge_push_notification,
        enable_free_downloads_email: seller.enable_free_downloads_email,
        enable_free_downloads_push_notification: seller.enable_free_downloads_push_notification,
        announcement_notification_enabled: seller.announcement_notification_enabled,
        disable_comments_email: seller.disable_comments_email,
        disable_reviews_email: seller.disable_reviews_email,
        disable_review_reminders: seller.disable_review_reminders?,
        show_nsfw_products: seller.show_nsfw_products?,
        disable_affiliate_requests: seller.disable_affiliate_requests?,
        seller_refund_policy:,
        product_level_support_emails: seller.product_level_support_emails
      }
    }
  end

  def application_props(application)
    {
      settings_pages: pages,
      application: {
        id: application.external_id,
        name: application.name,
        redirect_uri: application.redirect_uri,
        icon_url: application.icon_url,
        uid: application.uid,
        secret: application.secret,
      }
    }
  end

  def advanced_props
    if seller.custom_domain&.unverified?
      domain = seller.custom_domain.domain
      has_valid_configuration = CustomDomainVerificationService.new(domain:).process
      message = has_valid_configuration ? "#{domain} domain is correctly configured!"
                  : "Domain verification failed. Please make sure you have correctly configured the DNS record for #{domain}."
      custom_domain_verification_status = { success: has_valid_configuration, message: }
    else
      custom_domain_verification_status = nil
    end

    {
      settings_pages: pages,
      user_id: ObfuscateIds.encrypt(seller.id),
      notification_endpoint: seller.notification_endpoint || "",
      blocked_customer_emails: seller.blocked_customer_objects.active.email.pluck(:object_value).join("\n"),
      custom_domain_verification_status:,
      custom_domain_name: seller.custom_domain&.domain || "",
      applications: seller.oauth_applications.alive.map do |oauth_application|
        {
          id: oauth_application.external_id,
          name: oauth_application.name,
          icon_url: oauth_application.icon_url
        }
      end,
      allow_deactivation: Pundit.policy!(pundit_user, [:user]).deactivate?,
      formatted_balance_to_forfeit_on_account_deletion: seller.formatted_balance_to_forfeit(:account_closure),
    }
  end

  def billing_props
    billing_detail = seller.billing_detail
    {
      settings_pages: pages,
      billing_detail: {
        full_name: billing_detail&.full_name || seller.name.to_s,
        business_name: billing_detail&.business_name || "",
        business_id: billing_detail&.business_id || "",
        street_address: billing_detail&.street_address || "",
        city: billing_detail&.city || "",
        state: billing_detail&.state || "",
        zip_code: billing_detail&.zip_code || "",
        country_code: billing_detail&.country_code || "",
        additional_notes: billing_detail&.additional_notes || "",
        auto_email_invoice_enabled: billing_detail.nil? || billing_detail.auto_email_invoice_enabled,
      },
      # `billing_props` populates the seller's invoice address dropdown, not their compliance
      # country. A PR invoice address is legitimate (and may already exist on a BillingDetail
      # record), so the dropdown keeps the full ISO country list. Only `payments_props` —
      # which drives Stripe Connect onboarding and is gated by the issue #394 catch-22 —
      # filters out US outlying areas.
      countries: Compliance::Countries.for_select.to_h,
      business_id_country_codes: BusinessIdLabels::COUNTRY_CODES,
      business_id_labels: BusinessIdLabels::LABELS,
    }
  end

  def third_party_analytics_props
    {
      disable_third_party_analytics: seller.disable_third_party_analytics,
      google_analytics_id: seller.google_analytics_id || "",
      facebook_pixel_id: seller.facebook_pixel_id || "",
      tiktok_pixel_id: seller.tiktok_pixel_id || "",
      skip_free_sale_analytics: seller.skip_free_sale_analytics,
      facebook_meta_tag: seller.facebook_meta_tag || "",
      enable_verify_domain_third_party_services: seller.enable_verify_domain_third_party_services,
      snippets: seller.third_party_analytics.alive.map do |third_party_analytic|
        {
          id: third_party_analytic.external_id,
          product: third_party_analytic.link&.unique_permalink,
          name: third_party_analytic.name.presence || "",
          location: third_party_analytic.location,
          code: third_party_analytic.analytics_code,
        }
      end
    }
  end

  def password_props
    passkeys = seller.webauthn_credentials.order(:created_at).map do |credential|
      {
        id: credential.external_id,
        nickname: credential.nickname,
        created_at: credential.created_at.iso8601,
        last_used_at: credential.last_used_at&.iso8601,
      }
    end

    {
      require_old_password: seller.provider.blank?,
      settings_pages: pages,
      authenticator_app_enabled: seller.totp_enabled?,
      passkeys:,
    }
  end

  def authorized_applications_props
    authorized_applications = OauthApplication.alive.authorized_for(seller)
    application_grants = {}
    valid_applications = []

    authorized_applications.each do |application|
      access_grant = Doorkeeper::AccessGrant.order("created_at").where(application_id: application.id, resource_owner_id: seller.id).first
      next if access_grant.nil?

      valid_applications << application
      application_grants[application.id] = access_grant
    end
    valid_applications = valid_applications.sort_by { |application| application_grants[application.id].created_at }
    live_scopes = live_scopes_by_application(valid_applications.map(&:id))

    authorized_applications = valid_applications.map do |application| {
      name: application.name,
      icon_url: application.icon_url,
      is_own_app: application.owner == seller,
      first_authorized_at: application_grants[application.id].created_at.iso8601,
      scopes: live_scopes[application.id] || application_grants[application.id].scopes,
      id: application.external_id,
    } end

    {
      settings_pages: pages,
      authorized_applications:
    }
  end

  def payments_props(remote_ip: nil)
    user_compliance_info = seller.fetch_or_build_user_compliance_info
    payments_policy = Pundit.policy!(pundit_user, [:settings, :payments, seller])
    {
      settings_pages: pages,
      is_form_disabled: !payments_policy.update?,
      should_show_country_modal: !seller.fetch_or_build_user_compliance_info.country.present? &&
        payments_policy.set_country?,
      aus_backtax_details: aus_backtax_details(user_compliance_info),
      stripe_connect:,
      countries: Compliance::Countries.for_select_for_seller_compliance.to_h,
      ip_country_code: GeoIp.lookup(remote_ip)&.country_code,
      bank_account_details:,
      paypal_address: seller.payment_address,
      fee_info: fee_info(user_compliance_info),
      user: user_details(user_compliance_info),
      compliance_info: compliance_info_details(user_compliance_info),
      min_dob_year: Date.today.year - UserComplianceInfo::MINIMUM_DATE_OF_BIRTH_AGE,
      uae_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_UAE.map { |code, name| { code:, name: } },
      india_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_INDIA.map { |code, name| { code:, name: } },
      canada_business_types: UserComplianceInfo::BusinessTypes::BUSINESS_TYPES_CANADA.map { |code, name| { code:, name: } },
      states:,
      saved_card: CheckoutPresenter.saved_card(seller.credit_card),
      formatted_balance_to_forfeit_on_country_change: seller.formatted_balance_to_forfeit(:country_change),
      formatted_balance_to_forfeit_on_payout_method_change: seller.formatted_balance_to_forfeit(:payout_method_change),
      payouts_paused_internally: seller.payouts_paused_internally?,
      payouts_paused_by: seller.payouts_paused_by_source,
      account_status: account_status_details(payments_policy),
      payouts_paused_by_user: seller.payouts_paused_by_user?,
      payout_threshold_cents: seller.payout_threshold_cents,
      minimum_payout_threshold_cents: seller.minimum_payout_threshold_cents,
      payout_country_name: Compliance::Countries.for_select.to_h[seller.alive_user_compliance_info&.legal_entity_country_code],
      payout_frequency: seller.payout_frequency,
      payout_frequency_daily_supported: seller.instant_payouts_supported?,
      # Daily payouts are executed as Stripe instant payouts, so they carry the same
      # fee. Expose the canonical rate here so the settings UI can never drift from
      # what the payout processor actually charges.
      instant_payout_fee_percent: StripePayoutProcessor::INSTANT_PAYOUT_FEE_PERCENT,
      buyer_local_currency_enabled: Feature.active?(:buyer_local_currency, seller),
      disable_buyer_local_currency: seller.disable_buyer_local_currency?,
      # The rounding toggle only means anything for sellers whose buyers are actually
      # charged in their own currency, so the UI hides it unless charging is on too.
      buyer_currency_charging_enabled: Feature.active?(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller),
      disable_buyer_currency_rounding: seller.disable_buyer_currency_rounding?,
      can_manage_beneficial_owners: payments_policy.update? && StripeBeneficialOwnersManager.eligible?(seller),
      legal_guardian: legal_guardian_details(user_compliance_info),
    }
  end

  def seller_refund_policy
    # When a refund policy is enforced on the account (dispute rate got too high — see
    # Purchase::Blockable#enforce_refund_policy_for_seller_based_on_dispute_rate!), hide
    # the "No refunds allowed" (0-day) option from the settings dropdown. The model
    # validation on SellerRefundPolicy is the real guard; this keeps the UI honest.
    allowed_periods = RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.keys
    allowed_periods -= [0] if seller.refund_policy_enforced?

    {
      # The section always renders in Settings. When it isn't editable (account-level
      # refund policies are switched off and nothing is enforced on this account), the
      # UI shows the controls disabled with a note explaining why, instead of hiding
      # the section entirely.
      editable: seller.refund_policy_settings_editable?,
      refund_policy_enforced: seller.refund_policy_enforced?,
      allowed_refund_periods_in_days: allowed_periods.map do
        {
          key: _1,
          value: RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[_1]
        }
      end,
      max_refund_period_in_days: seller.refund_policy.max_refund_period_in_days,
      fine_print: seller.refund_policy.fine_print,
      fine_print_enabled: seller.refund_policy.fine_print.present?,
    }
  end

  private
    # Application id => what this seller's usable tokens for it can actually reach. Applications
    # with no usable token left are absent rather than empty.
    #
    # The union across usable tokens, not the first grant's scopes: the device flow mints a fresh
    # grant per scope set, so a seller who re-authorized with a broader set kept seeing the
    # narrower list from their first grant while holding a token that could reach refunds and
    # payout data. `not_expired` rather than Doorkeeper's `active_for`, which only checks
    # `revoked_at` — every CLI token has a nil `expires_in` today, but an expired one can reach
    # nothing and must not read as a capability once device tokens start expiring.
    def live_scopes_by_application(application_ids)
      return {} if application_ids.empty?

      Doorkeeper::AccessToken
        .by_resource_owner(seller)
        .not_expired
        .where(application_id: application_ids)
        .pluck(:application_id, :scopes)
        .group_by(&:first)
        .each_with_object({}) do |(application_id, rows), result|
          scopes = rows.flat_map { |(_, value)| value.to_s.split }.uniq
          result[application_id] = Doorkeeper::OAuth::Scopes.from_array(scopes) if scopes.present?
        end
    end

    # Always a complete hash: an omitted key is `undefined` in the component and
    # truthy under `!== null`, which would show this section to sellers who must
    # never see it. `required` and `unsupported` stay separate — they drive
    # different copy (US minor vs no-guardian-path country).
    def legal_guardian_details(user_compliance_info)
      guardian = user_compliance_info.guardian

      # Self-connected Stripe: never ask (no Gumroad-managed account for a guardian).
      # Same predicate as the payout gate, not has_stripe_account_connected?: a
      # Brazilian Connect account is not payable by Stripe, so the gate still
      # applies — the broader check would hide this from the minor the gate blocks.
      if StripePayoutProcessor.pays_user_via_stripe_connect?(seller)
        return { required: false, unsupported: false, blocking_payouts: false, guardian: nil }
      end

      required = user_compliance_info.requires_legal_guardian?
      unsupported = user_compliance_info.legal_guardian_unsupported?

      {
        required:,
        unsupported:,
        # Guardian-requirement hold only — not "payouts blocked for any reason".
        # Same predicate as the payout gate, not recomputed from the flags above.
        blocking_payouts: !user_compliance_info.legal_guardian_requirement_met?,
        guardian: guardian.present? && guardian.alive? ? GuardianPresenter.new(guardian).props : nil,
      }
    end

    # Newest alive admin postal-code payout note. Notes clear only on SUCCESS, so a
    # later unrelated failure leaves the old note alive. Treat it as current only
    # when it postdates the latest UserComplianceInfo (form save replaces the row).
    def postal_code_rejected_by_stripe?
      note = seller.comments
            .with_type_payout_note
            .alive
            .where(author_id: GUMROAD_ADMIN_ID)
            .where("content LIKE ?", "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}%")
            .order(created_at: :desc, id: :desc)
            .first
      return false if note.nil?

      compliance_info = seller.alive_user_compliance_info
      compliance_info.nil? || note.created_at >= compliance_info.created_at
    end

    # Newest bank-rejection note for the current bank row, or nil.
    # Freshness is the active BankAccount#created_at: replacing bank details
    # inserts a new row (holder-name-only updates in place). No alive bank
    # account → nil (PayPal switch deletes the row and never clears the note).
    def current_bank_sync_failure_note
      bank_account = seller.active_bank_account
      return nil if bank_account.nil?

      # A Connect seller is paid through their own account, so a rejected Gumroad-managed bank
      # account blocks nothing — and the banner would never clear, since bank notes are only
      # soft-deleted by a managed-account sync that cannot run while Connect is active.
      return nil if seller.has_stripe_account_connected?

      notes = seller.comments
            .with_type_payout_note
            .alive
            .where(author_id: GUMROAD_ADMIN_ID)
            .where("content LIKE ?", "#{StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX}%")
            .order(created_at: :desc, id: :desc)

      # Prefer a note that names this bank row. Newest-first alone is not enough: the sync makes
      # network calls, so a rejection for a replaced row can be written AFTER the seller saved
      # the replacement, and that stale note would otherwise win on timestamp and show the wrong
      # account's guidance.
      notes.find { |note| note.json_data["bank_account_id"] == bank_account.id } ||
        # Notes recorded before we stamped the row fall back to the timestamp cutoff. An equal
        # timestamp still counts: the note is always written after the row it describes.
        notes.find do |note|
          note.json_data["bank_account_id"].nil? && note.created_at >= bank_account.created_at
        end
    end

    def country_code_for_compliance_field(field, user_compliance_info)
      case field
      when UserComplianceInfoFields::Business::TAX_ID, UserComplianceInfoFields::Business::VAT_NUMBER
        user_compliance_info.business_country_code
      when UserComplianceInfoFields::Individual::TAX_ID
        user_compliance_info.country_code
      else
        user_compliance_info.legal_entity_country_code
      end
    end

    def account_status_details(payments_policy)
      pending_compliance = seller.user_compliance_info_requests.requested.exists?
      is_suspended = seller.suspended?
      is_under_review = seller.on_probation? || seller.flagged?
      payouts_paused_not_by_user = seller.payouts_paused_internally?

      payouts_paused_by_user = seller.payouts_paused_by_user?
      suspension_reason = if seller.suspended_for_fraud?
        "Your account has been suspended due to fraudulent activity."
      elsif seller.suspended_for_tos_violation?
        "Your account has been suspended for a policy violation."
      end

      id_document_fields = [
        UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID,
        UserComplianceInfoFields::Individual::PASSPORT,
        UserComplianceInfoFields::Individual::VISA,
        UserComplianceInfoFields::Individual::STRIPE_ENHANCED_IDENTITY_VERIFICATION,
      ]
      needs_id_upload = seller.user_compliance_info_requests.requested
        .where(field_needed: id_document_fields).exists?

      stripe_account = seller.stripe_account
      # Only show the terminal "Stripe rejected your account / Gumroad cannot
      # reverse this" banner when the rejection really is final. A rejected
      # account that still has an open verification request is the appealable
      # fork (e.g. Japan `rejected.listed` with a live identity-document
      # request) — that seller keeps the normal compliance-actions UI and their
      # remediation link instead of a dead-end banner.
      stripe_rejected = (stripe_account&.stripe_rejected? || false) &&
        !seller.user_compliance_info_requests.requested.exists?

      # Zero balance → nil (don't mention a missing balance). Rejected accounts
      # bypass the $100 minimum; too_small is the $1 transfer floor.
      stripe_rejected_balance_status = nil
      stripe_rejected_formatted_balance = nil
      stripe_rejected_payout_date = nil
      if stripe_rejected
        balance_cents = seller.unpaid_balance_cents
        stripe_rejected_formatted_balance = seller.formatted_dollar_amount(balance_cents) if balance_cents > 0
        stripe_rejected_balance_status = if balance_cents <= 0
          nil
        elsif balance_cents < Payouts::REJECTED_ACCOUNT_MIN_AMOUNT_CENTS
          "too_small"
        elsif seller.payouts_paused_internally? && seller.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE
          "stripe_hold"
        elsif seller.payouts_paused?
          # Paused by admin or by the seller themselves — the automatic payout
          # will not run, so don't promise it ("auto_payout") and don't blame
          # Stripe ("stripe_hold"). The generic "held" copy points at support.
          "held"
        else
          "auto_payout"
        end
        # Only the auto-payout copy names a date — the other states can't
        # promise one. The banner falls back to "your next scheduled payout"
        # if the date can't be computed for any reason.
        if stripe_rejected_balance_status == "auto_payout"
          stripe_rejected_payout_date = seller.next_payout_date&.strftime("%B %-d, %Y")
        end
      end

      # Stripe interventions never create a UserComplianceInfoRequest row, so an
      # intervention-only account has something past_due on Stripe's side and
      # nothing pending on ours. Offering the link off the Stripe-side pause as
      # well is safe: #remediation re-reads the live requirements and bounces to
      # "you're all set" when nothing is open, so a stale pause costs one click.
      paused_by_stripe = seller.payouts_paused_internally? &&
        seller.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE

      compliance_actions = []
      if (pending_compliance || paused_by_stripe) && stripe_account.present? && !stripe_rejected && payments_policy.update?
        compliance_actions << { message: "Complete pending verification requirements via Stripe", href: remediation_settings_payments_path }
      end
      if pending_compliance && stripe_account.blank?
        user_compliance_info = seller.fetch_or_build_user_compliance_info
        missing_fields = []
        seller.user_compliance_info_requests.requested.each do |request|
          if request.verification_error_message.present?
            compliance_actions << { message: "#{request.verification_error_message.strip.sub(/[.!?]+\z/, "")}.", href: nil }
          else
            country_code = country_code_for_compliance_field(request.field_needed, user_compliance_info)
            missing_fields << UserComplianceInfoFieldProperty.name_tag_for_field(request.field_needed, country: country_code)
          end
        end
        if missing_fields.any?
          compliance_actions << { message: "Please provide: #{missing_fields.uniq.to_sentence}.", href: nil }
        end
      end

      # Stripe rejects the postal code asynchronously, after the settings page has already
      # reported a clean save. Gated on a missing account because a rejection only blocks a
      # seller who has no payout account yet; freshness is postal_code_rejected_by_stripe?'s job.
      if stripe_account.blank? && postal_code_rejected_by_stripe?
        country = seller.alive_user_compliance_info&.legal_entity_country
        weeks = RetryStripeRejectedPayoutSetupsJob::RETRY_WINDOW_WEEKS
        compliance_actions << {
          message: "Our payment partner couldn't verify the postal code you entered#{" for #{country}" if country.present?}. Please double-check it and re-save your address. If you're sure it's correct (for example, a newly built address), you don't need to do anything — we'll automatically re-check it once a week for up to #{weeks} weeks.",
          href: nil,
        }
      end

      # Bank details can fail after a clean settings save. Do not gate on a missing
      # Stripe account (unlike postal): update_bank_account needs a live account.
      # Terminal-rejection banner wins. Order matches bank_rejection_kind_for
      # (narrowest first); copy must match the email. Unknown abandoned_reason → skip.
      if !stripe_rejected && (bank_note = current_bank_sync_failure_note)
        abandoned_reason = bank_note.json_data["abandoned_reason"]
        bank_message = if StripeMerchantAccountManager.bank_account_blocked_note?(bank_note)
          # Same ask as the terminal branch, but this copy says the details were fine.
          "Our payment partner won't accept the bank account you added, and there's nothing wrong with the details you entered — re-entering them or waiting won't help. Please add a different bank account. If it's the only account you have, contact support and we'll look into it with you."
        elsif StripeMerchantAccountManager.bank_details_terminal_rejection_note?(bank_note)
          "Our payment partner won't accept the bank account you entered, so it can't be used for payouts. This won't clear on its own, and re-entering the same account won't help. Please add a different bank account."
        elsif StripeMerchantAccountManager.bank_details_format_rejection_note?(bank_note)
          "Our payment partner couldn't accept your bank details as entered. Please double-check your account and bank code and re-save them. Waiting won't clear this one."
        elsif bank_note.json_data["abandoned_at"].present?
          # give_up! abandons without a reason, and it counts transient failures toward the retry
          # cap too, so exhaustion is not evidence the details are wrong. Mirrors
          # ContactingCreatorMailer#payout_setup_retry_exhausted, sent from that same method.
          "We've been re-checking the bank account you added, but our payment partner still hasn't been able to verify it. Please double-check your details and re-save them. If everything looks correct, contact support and we'll look into it." if abandoned_reason.blank?
        else
          # Cadence wording must match ContactingCreatorMailer#invalid_bank_account.
          # Quote the row the note names, not the active one. A legacy note with no
          # bank_account_id reaches here through the selector's timestamp fallback and may
          # describe a row the seller has already replaced, so it quotes nothing and keeps the
          # generic sentence. Mirrors ContactingCreatorMailer#rejected_bank_account.
          if StripeMerchantAccountManager.bank_details_directory_miss_note?(bank_note)
            refused_bank_account = seller.bank_accounts.find_by(id: bank_note.json_data["bank_account_id"])
            directory_detail = StripeMerchantAccountManager.bank_directory_miss_detail(refused_bank_account)
          end
          ["Our payment partner couldn't verify the bank account you entered.",
           directory_detail,
           "Please double-check your details and re-save them. If you're sure they're correct (for example, a newly opened account), you don't need to do anything — we'll automatically re-check it once a week for up to #{RetryStripeRejectedPayoutSetupsJob::RETRY_WINDOW_WEEKS} weeks."].compact.join(" ")
        end
        compliance_actions << { message: bank_message, href: nil } if bank_message.present?
      end

      gumroad_status = if is_under_review && !is_suspended
        "Your account is under review and payouts are on hold until it's resolved."
      end

      show_section = is_suspended || is_under_review || payouts_paused_not_by_user || payouts_paused_by_user || compliance_actions.any? || stripe_rejected

      {
        show_section:,
        is_suspended:,
        suspension_reason:,
        compliance_actions:,
        needs_id_upload:,
        gumroad_status:,
        stripe_rejected:,
        stripe_rejected_balance_status:,
        stripe_rejected_formatted_balance:,
        stripe_rejected_payout_date:,
      }
    end

    def user_details(user_compliance_info)
      # Memoize: evaluated for both need_full_ssn and has_outstanding_full_ssn_requirement below,
      # and each call re-queries — a second query could see a request marked provided in between.
      outstanding_full_ssn_requirement = has_outstanding_full_ssn_requirement?
      {
        country_supports_native_payouts: seller.native_payouts_supported?,
        no_payout_rail_in_country: seller.no_payout_rail_in_compliance_country?,
        country_supports_iban: seller.country_supports_iban?,
        need_full_ssn: outstanding_full_ssn_requirement,
        country_code: user_compliance_info.legal_entity_country_code,
        payout_currency: Country.new(user_compliance_info.legal_entity_country_code).payout_currency,
        is_from_europe: seller.signed_up_from_europe?,
        individual_tax_id_needed_countries: [Compliance::Countries::USA.alpha2,
                                             Compliance::Countries::CAN.alpha2,
                                             Compliance::Countries::HKG.alpha2,
                                             Compliance::Countries::SGP.alpha2,
                                             Compliance::Countries::ARE.alpha2,
                                             Compliance::Countries::MEX.alpha2,
                                             Compliance::Countries::BGD.alpha2,
                                             Compliance::Countries::MOZ.alpha2,
                                             Compliance::Countries::URY.alpha2,
                                             Compliance::Countries::ARG.alpha2,
                                             Compliance::Countries::PER.alpha2,
                                             Compliance::Countries::CRI.alpha2,
                                             Compliance::Countries::CHL.alpha2,
                                             Compliance::Countries::COL.alpha2,
                                             Compliance::Countries::GTM.alpha2,
                                             Compliance::Countries::DOM.alpha2,
                                             Compliance::Countries::BOL.alpha2,
                                             Compliance::Countries::KAZ.alpha2,
                                             Compliance::Countries::PRY.alpha2,
                                             Compliance::Countries::PAK.alpha2],
        individual_tax_id_entered: user_compliance_info.individual_tax_id.present?,
        individual_tax_id_last_four: tax_id_last_four(user_compliance_info.individual_tax_id),
        individual_tax_id_is_last_four: tax_id_is_last_four_only?(user_compliance_info.individual_tax_id),
        has_outstanding_full_ssn_requirement: outstanding_full_ssn_requirement,
        business_tax_id_entered: user_compliance_info.business_tax_id.present?,
        business_tax_id_last_four: tax_id_last_four(user_compliance_info.business_tax_id),
        requires_credit_card: seller.requires_credit_card?,
        is_charged_paypal_payout_fee: seller.charge_paypal_payout_fee?,
        joined_at: seller.created_at.iso8601
      }
    end

    # Strongbox decryption returns a BINARY (ASCII-8BIT) string, and older records can
    # contain Unicode whitespace (for example U+202F narrow no-break space from a
    # locale-formatted paste) that predates write-time normalization. Slicing such a
    # value with [-4..] operates on bytes and can cut a multi-byte character in half,
    # producing invalid UTF-8 that crashes JSON serialization of the page props and
    # 500s the entire settings page. Force UTF-8, drop any invalid bytes, and strip
    # Unicode whitespace before taking the last four characters.
    def tax_id_last_four(encrypted_tax_id)
      return nil if encrypted_tax_id.blank?
      decrypted = encrypted_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).to_s
      decrypted.force_encoding(Encoding::UTF_8).scrub("").gsub(/[[:space:]]/, "")[-4..]
    end

    # Only an OUTSTANDING full (not partial/ssn_last_4) TAX_ID request should force re-entry.
    # `has_ever_been_requested_...` is ever-based, so a seller who long ago cleared id_number via
    # document upload (last-4 still on file) would otherwise be forced to re-enter an SSN Stripe
    # no longer wants — on every payments-form save, forever.
    def has_outstanding_full_ssn_requirement?
      seller.user_compliance_info_requests
            .requested
            .where(field_needed: UserComplianceInfoFields::Individual::TAX_ID)
            .only_needs_field_to_be_partially_provided(false)
            .exists?
    end

    # Stripe can require a full 9-digit SSN (individual.id_number) after onboarding, but sellers
    # who signed up when only ssn_last_4 was collected have just 4 digits on file — the sync job
    # can never satisfy the requirement, so the UI must force re-entry.
    def tax_id_is_last_four_only?(encrypted_tax_id)
      return false if encrypted_tax_id.blank?
      decrypted = encrypted_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).to_s
      decrypted.force_encoding(Encoding::UTF_8).scrub("").gsub(/\D/, "").length == 4
    end

    def compliance_info_details(user_compliance_info)
      {
        is_business: user_compliance_info.is_business?,
        business_name: user_compliance_info.business_name,
        business_name_kanji: user_compliance_info.business_name_kanji,
        business_name_kana: user_compliance_info.business_name_kana,
        business_type: user_compliance_info.business_type,
        business_street_address: user_compliance_info.business_street_address,
        business_building_number: user_compliance_info.business_building_number,
        business_building_number_kana: user_compliance_info.business_building_number_kana,
        business_street_address_kanji: user_compliance_info.business_street_address_kanji,
        business_street_address_kana: user_compliance_info.business_street_address_kana,
        business_city: user_compliance_info.business_city,
        business_city_kana: user_compliance_info.business_city_kana,
        business_state: user_compliance_info.business_state,
        business_country: user_compliance_info.business_country_code || user_compliance_info.country_code,
        business_zip_code: user_compliance_info.business_zip_code,
        business_phone: user_compliance_info.business_phone,
        job_title: user_compliance_info.job_title,
        first_name: user_compliance_info.first_name,
        last_name: user_compliance_info.last_name,
        first_name_kanji: user_compliance_info.first_name_kanji,
        last_name_kanji: user_compliance_info.last_name_kanji,
        first_name_kana: user_compliance_info.first_name_kana,
        last_name_kana: user_compliance_info.last_name_kana,
        street_address: user_compliance_info.street_address,
        building_number: user_compliance_info.building_number,
        building_number_kana: user_compliance_info.building_number_kana,
        street_address_kanji: user_compliance_info.street_address_kanji,
        street_address_kana: user_compliance_info.street_address_kana,
        city: user_compliance_info.city,
        city_kana: user_compliance_info.city_kana,
        state: user_compliance_info.state,
        country: user_compliance_info.country_code,
        zip_code: user_compliance_info.zip_code,
        phone: user_compliance_info.phone,
        nationality: user_compliance_info.nationality,
        dob_month: user_compliance_info.birthday.try(:month).to_i,
        dob_day: user_compliance_info.birthday.try(:day).to_i,
        dob_year: user_compliance_info.birthday.try(:year).to_i,
      }
    end

    def bank_account_details
      bank_account = seller.active_bank_account

      {
        show_bank_account: seller.can_setup_bank_payouts?,
        show_paypal: seller.can_setup_paypal_payouts?,
        card_data_handling_mode: CardDataHandlingMode.get_card_data_handling_mode(seller),
        is_a_card: bank_account.is_a?(CardBankAccount),
        card: bank_account.is_a?(CardBankAccount) ? {
          type: bank_account.credit_card.card_type,
          number: bank_account.credit_card.visual,
          expiration_date: bank_account.credit_card.expiry_visual,
          requires_mandate: false
        } : nil,
        routing_number: bank_account.present? && !bank_account.is_a?(CardBankAccount) ? bank_account.routing_number : nil,
        account_number_visual: bank_account.present? && !bank_account.is_a?(CardBankAccount) ? bank_account.account_number_visual : nil,
        bank_account: bank_account.present? && !bank_account.is_a?(CardBankAccount) ? {
          account_holder_full_name: bank_account.account_holder_full_name,
        } : nil,
      }
    end

    def aus_backtax_details(user_compliance_info)
      {
        show_au_backtax_prompt: seller.au_backtax_owed_cents >= User::MIN_AU_BACKTAX_OWED_CENTS_FOR_CONTACT &&
          AustraliaBacktaxEmailInfo.where(user_id: seller.id).exists?,
        total_amount_to_au: Money.new(seller.au_backtax_sales_cents).format(no_cents_if_whole: false, symbol: true),
        au_backtax_amount: Money.new(seller.au_backtax_owed_cents).format(no_cents_if_whole: false, symbol: true),
        opt_in_date: seller.au_backtax_agreement_date&.strftime("%B %e, %Y"),
        credit_creation_date: seller.credit_creation_date,
        opted_in_to_au_backtax: seller.opted_in_to_australia_backtaxes?,
        legal_entity_name: user_compliance_info.legal_entity_name,
        are_au_backtaxes_paid: seller.paid_for_austalia_backtaxes?,
        au_backtaxes_paid_date: seller.date_paid_australia_backtaxes,
      }
    end

    def stripe_connect
      {
        has_connected_stripe: seller.stripe_connect_account.present?,
        stripe_connect_account_id: seller.stripe_connect_account&.charge_processor_merchant_id,
        stripe_disconnect_allowed: seller.stripe_disconnect_allowed?,
        supported_countries_help_text: "This feature is available in <a href='https://stripe.com/en-in/global'>all countries where Stripe operates</a>, except India, Indonesia, Malaysia, Mexico, Philippines, and Thailand.",
      }
    end

    def states
      {
        us: Compliance::Countries.subdivisions_for_select(Compliance::Countries::USA.alpha2).map { |code, name| { code:, name: } },
        ca: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map { |code, name| { code:, name: } },
        au: Compliance::Countries.subdivisions_for_select(Compliance::Countries::AUS.alpha2).map { |code, name| { code:, name: } },
        mx: Compliance::Countries.subdivisions_for_select(Compliance::Countries::MEX.alpha2).map { |code, name| { code:, name: } },
        ae: Compliance::Countries.subdivisions_for_select(Compliance::Countries::ARE.alpha2).map { |code, name| { code:, name: } },
        ir: Compliance::Countries.subdivisions_for_select(Compliance::Countries::IRL.alpha2).map { |code, name| { code:, name: } },
        br: Compliance::Countries.subdivisions_for_select(Compliance::Countries::BRA.alpha2).map { |code, name| { code:, name: } },
        jp: Compliance::Countries.japan_prefectures_for_select,
      }
    end

    def fee_info(user_compliance_info)
      processor_fee_percent = (Purchase::PROCESSOR_FEE_PER_THOUSAND / 10.0).round(1)
      processor_fee_percent = processor_fee_percent.to_i == processor_fee_percent ? processor_fee_percent.to_i : processor_fee_percent
      processor_fee_fixed_cents = Purchase::PROCESSOR_FIXED_FEE_CENTS

      discover_fee_percent = (Purchase::GUMROAD_DISCOVER_FEE_PER_THOUSAND / 10.0).round(1)
      discover_fee_percent = discover_fee_percent.to_i == discover_fee_percent ? discover_fee_percent.to_i : discover_fee_percent
      direct_fee_percent = (seller.gumroad_fee_per_thousand / 10.0).round(1)
      direct_fee_percent = direct_fee_percent.to_i == direct_fee_percent ? direct_fee_percent.to_i : direct_fee_percent
      fixed_fee_cents = Purchase::GUMROAD_FIXED_FEE_CENTS

      if user_compliance_info&.country_code == Compliance::Countries::BRA.alpha2
        {
          card_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢ Gumroad fee + #{processor_fee_percent}% + #{processor_fee_fixed_cents}¢ credit card fee.\n• Discover sales: #{discover_fee_percent}% flat\n",
          connect_account_fee_info_text: "All sales will incur a 0% Gumroad fee.",
          paypal_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢ Gumroad fee + #{processor_fee_percent}% + #{processor_fee_fixed_cents}¢ PayPal fee.\n• Discover sales: #{discover_fee_percent}% flat\n"
        }
      else
        {
          card_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢ Gumroad fee + #{processor_fee_percent}% + #{processor_fee_fixed_cents}¢ credit card fee.\n• Discover sales: #{discover_fee_percent}% flat\n",
          connect_account_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢\n• Discover sales: #{discover_fee_percent}% flat\n",
          paypal_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢ Gumroad fee + #{processor_fee_percent}% + #{processor_fee_fixed_cents}¢ PayPal fee.\n• Discover sales: #{discover_fee_percent}% flat\n",
        }
      end
    end
end
