# frozen_string_literal: true

# A seller's explicit request for a Gumroad-managed Stripe payout rail (bank account or debit card)
# next to a stored Connect link that is not routing card sales. The candidate row is born deleted
# and the managed account is provisioned without charge_processor_alive_at, so neither is reachable
# by charges, payouts or User#active_bank_account until StripePayoutRailSetups::Activate switches
# them on together.
class StripePayoutRailSetup < ApplicationRecord
  PENDING = "pending"
  # The managed account exists, but a debit card can only be attached once Stripe enables charges.
  AWAITING_CARD_LINK = "awaiting_card_link"
  PREPARED = "prepared"
  FAILED = "failed"
  ACTIVATED = "activated"
  STATES = [PENDING, AWAITING_CARD_LINK, PREPARED, FAILED, ACTIVATED].freeze
  OPEN_STATES = [PENDING, AWAITING_CARD_LINK, PREPARED].freeze
  # Failure codes that are not about the instrument the seller submitted, so the page does not
  # report them as a refusal.
  # An older not-live managed account blocks a new one; only a support repair clears it.
  FOREIGN_BLOCKER_FAILURE_CODE = "existing_managed_account"
  INTERNAL_FAILURE_CODES = %w[cancelled_by_staff connect_removed country_changed connect_route_active].push(FOREIGN_BLOCKER_FAILURE_CODE).freeze
  # Guardian attributes that are bookkeeping rather than details sent to Stripe.
  GUARDIAN_FINGERPRINT_IGNORED_ATTRIBUTES = %w[id created_at updated_at stripe_person_id].freeze

  belongs_to :user
  belongs_to :bank_account
  belongs_to :merchant_account, optional: true
  belongs_to :activated_by, class_name: "User", optional: true

  validates :state, inclusion: { in: STATES }
  validates :consent_reference, length: { maximum: 255 }

  scope :open, -> { where(state: OPEN_STATES) }

  def self.open_for(user)
    open.where(user_id: user.id).order(:id).last
  end

  # The most recent setup, when it ended because Stripe refused what the seller submitted.
  def self.refused_for(user)
    latest = where(user_id: user.id).order(:id).last
    latest if latest&.state == FAILED && INTERNAL_FAILURE_CODES.exclude?(latest.failure_code)
  end

  # True while the seller's latest setup ended on an older managed account that still blocks a new one,
  # so the page asks for support instead of inviting a submission that would fail the same way.
  def self.support_required_for(user)
    latest = where(user_id: user.id).order(:id).last
    latest&.state == FAILED && latest.failure_code == FOREIGN_BLOCKER_FAILURE_CODE && latest.foreign_blocking_account.present?
  end

  # Identifies the guardian details a minor seller's account is given, or nil when no guardian is
  # involved. The compliance revision is part of it because guardian_id is attached in place.
  def self.guardian_fingerprint(user)
    info = user.alive_user_compliance_info
    return if info.nil? || (!info.requires_legal_guardian? && info.guardian_id.nil?)

    # Byte-wise, since the encrypted columns hold binary ciphertext.
    guardian_fields = info.guardian&.attributes&.except(*GUARDIAN_FINGERPRINT_IGNORED_ATTRIBUTES).to_a.sort.map { |name, value| name.b + "=".b + value.to_s.b }
    Digest::SHA256.hexdigest([info.external_id.to_s.b, info.guardian_id.to_s.b, *guardian_fields].join("\0".b))
  end

  # A setup only exists beside a stored Connect row; once that row or the legal entity is gone, the
  # prepared account would just block an ordinary managed account.
  def self.abandon_open_for!(user, failure_code)
    open.where(user_id: user.id).find_each { _1.abandon!(failure_code) }
  end

  # Stripe reports what it still needs for an account that is not live only through account.updated,
  # which the ordinary requirements handling skips for such accounts. Recorded once per change so
  # support can see why an open setup is not becoming ready.
  def self.record_provider_requirements!(stripe_account)
    requirements = stripe_account["requirements"] || {}
    fields = (Array(requirements["currently_due"]) + Array(requirements["past_due"])).uniq
    disabled_reason = requirements["disabled_reason"].presence
    return if fields.empty? && disabled_reason.nil?

    setup = open.joins(:merchant_account).find_by(merchant_accounts: { charge_processor_merchant_id: stripe_account["id"], deleted_at: nil })
    return if setup.nil?

    content = "Payout rail setup ##{setup.id}: Stripe still needs #{fields.presence&.join(", ") || "nothing listed"}#{" (#{disabled_reason})" if disabled_reason}."
    return if setup.user.comments.alive.with_type_payout_note.where(content:).exists?

    setup.user.add_payout_note(content:, seller_visible: false)
  end

  # Returns the new attempt token, or nil when the setup is not in `state` or another attempt still
  # holds an unexpired lease. Every later transition of this attempt must present the token.
  def self.claim_attempt!(setup_id, lease:, state: PENDING)
    token = SecureRandom.uuid
    now = Time.current
    claimed = where(id: setup_id, state:)
      .where("attempt_started_at IS NULL OR attempt_started_at <= ?", now - lease)
      .update_all(["attempt_token = ?, attempt_started_at = ?, attempt_count = attempt_count + 1, updated_at = ?", token, now, now])
    claimed == 1 ? token : nil
  end

  def pending?
    state == PENDING
  end

  def awaiting_card_link?
    state == AWAITING_CARD_LINK
  end

  def prepared?
    state == PREPARED
  end

  def card?
    bank_account.is_a?(CardBankAccount)
  end

  # Not-live managed rows create_account opened for this setup, including one an interrupted attempt
  # never recorded in merchant_account_id. Ownership is the tag written before Stripe was called.
  def owned_unlive_accounts
    user.merchant_accounts.alive.stripe.where(charge_processor_alive_at: nil)
        .select { |account| account.rail_setup_id == id.to_s && !account.is_a_stripe_connect_account? }
  end

  # A not-live managed row with a Stripe id that predates this setup can only be another context's,
  # never an overlapping attempt of this one, which create_account starts after the setup exists.
  def foreign_blocking_account
    user.merchant_accounts.alive.stripe
        .where(charge_processor_alive_at: nil)
        .where.not(charge_processor_merchant_id: nil)
        .where(created_at: ...created_at)
        .reject { |account| account.is_a_stripe_connect_account? || account.rail_setup_id == id.to_s }
        .first
  end

  # Provider work for a setup stops once the seller leaves the rollout (an unreadable flag counts as
  # closed), is suspended, has Connect routing card sales, or no longer has the stored Connect row the
  # setup was staged beside.
  def provider_work_allowed?
    !user.suspended? && user.payout_rail_beside_inactive_connect_enabled? && !user.has_stripe_account_connected? &&
      user.stripe_connect_account.present?
  end

  # Applies attributes only while this attempt still owns the setup, then forgets the attempt. A
  # stale worker whose lease was reclaimed gets false and changes nothing.
  def finish_attempt!(token, from_state: PENDING, **attributes)
    return false if token.blank?

    updated = self.class.where(id:, state: from_state, attempt_token: token)
      .update_all(attributes.merge(attempt_token: nil, attempt_started_at: nil, updated_at: Time.current))
    reload
    updated == 1
  end

  def mark_failed!(failure_code)
    update!(state: FAILED, failure_code: failure_code.to_s.truncate(255), failed_at: Time.current, attempt_token: nil, attempt_started_at: nil)
  end

  # Once this setup has ended, retires the not-live account prepared for it, which would otherwise
  # block every later managed account. Local only, keeping the provider id; an account that an open
  # or activated setup points at is left alone.
  def retire_prepared_account!(account = merchant_account)
    return false if account.nil?

    user.with_lock do
      reload
      next false if OPEN_STATES.include?(state) || state == ACTIVATED

      account = MerchantAccount.lock.find(account.id)
      next false unless account.user_id == user_id && account.alive? && !account.charge_processor_alive? && !account.is_a_stripe_connect_account?
      next false if self.class.where(merchant_account_id: account.id, state: OPEN_STATES + [ACTIVATED]).exists?

      account.delete_charge_processor_account!
      true
    end
  end

  # Once the setup has ended, its account-creation recovery notes stop being retried, but they keep
  # their idempotency key and attempt time: they are the record of what Stripe may have created.
  def abandon_recovery_notes!
    user.comments.alive.with_type_payout_note
        .where(author_id: GUMROAD_ADMIN_ID)
        .where("content LIKE ?", "#{StripeMerchantAccountManager::NO_VERDICT_FAILURE_NOTE_PREFIX}%")
        .select { |note| note.json_data[StripeMerchantAccountManager::RAIL_SETUP_ID_NOTE_KEY] == id.to_s && note.json_data["abandoned_at"].blank? }
        .each do |note|
          note.json_data["abandoned_at"] = Time.current.iso8601
          note.json_data["abandoned_reason"] = "rail_setup_ended"
          note.save!
        end
  end

  # Local only, like UpdateUserCountry's own retirement of the managed account: the provider
  # account is left for the existing cleanup paths rather than deleted from here. Takes the seller
  # lock Activate holds, so a setup activated meanwhile is left alone instead of half-switched.
  def abandon!(failure_code)
    user.with_lock do
      reload
      next false unless OPEN_STATES.include?(state)

      [merchant_account, *owned_unlive_accounts].compact.uniq.each do |account|
        next unless account.alive? && !account.charge_processor_alive?
        next if self.class.where(merchant_account_id: account.id, state: OPEN_STATES + [ACTIVATED]).where.not(id:).exists?

        account.delete_charge_processor_account!
      end
      mark_failed!(failure_code)
      abandon_recovery_notes!
      true
    end
  end
end
