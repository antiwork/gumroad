# frozen_string_literal: true

# Keeps the legal guardian of an under-18 seller in sync with the Stripe Person that represents
# them on the seller's payout account.
#
# Stripe will not verify a 13-17 year old as the sole Person on a Custom account. Once the account
# representative's date of birth says they are a minor, Stripe raises a requirement for a second
# Person carrying relationship.legal_guardian, verifies that adult instead, and expects the adult —
# not the minor — to accept its terms. The minor stays the account holder and the payouts stay in
# their name, which is the point.
#
# Lives beside StripeBeneficialOwnersManager rather than inside StripeMerchantAccountManager: both
# are "a second Person on the seller's account", and the merchant-account manager is already 2000
# lines. The merchant-account manager calls in at the two moments the account is written.
#
# When the requirement ends — the seller turns 18, or moves to a country without a guardian path —
# sync stops sending the guardian but the Person already at Stripe is left in place. Deliberate for
# now: Stripe drops the requirement on its own and a lingering verified Person does not block
# payouts, whereas deleting one mid-verification would. Revisit alongside the form in PR 3, which is
# where a seller can act on it. Erasure still reaches it, by the recorded id.
module StripeGuardianManager
  # Raised when the per-guardian sync lock cannot be taken. Not a Stripe failure: nothing was sent.
  class SyncLockUnavailable < StandardError; end

  # Stripe validates an identity number against the ACCOUNT's country, not the person's, and expects
  # 9 digits for a US account. See StripeMerchantAccountManager.person_hash, which carries the same
  # rule for the representative.
  US_SSN_LAST_4_LENGTH = 4
  US_FULL_TAX_ID_LENGTH = 9

  # Long enough to cover a retrieve plus a create/update round trip to Stripe, short enough that a
  # process killed mid-sync does not block the next one for long.
  SYNC_LOCK_TTL = 30.seconds
  SYNC_LOCK_WAIT_TIMEOUT = 10.seconds
  SYNC_LOCK_RETRY_INTERVAL_SECONDS = 0.05
  SYNC_LOCK_RELEASE_SCRIPT = <<~LUA.squish
    if redis.call('get', KEYS[1]) == ARGV[1] then
      return redis.call('del', KEYS[1])
    end
    return 0
  LUA

  # Creates or updates the guardian's Stripe Person, and records the id Stripe assigns.
  #
  # Only syncs a guardian we hold complete details for. A partial Person is worse than none: it
  # commits the account to a legal-guardian requirement that the partial data cannot satisfy, so the
  # account sits on an unmet requirement instead of on no requirement at all. What "complete" means
  # is Guardian#has_completed_info?, the same predicate the payout gate reads, so the two can never
  # disagree about whether this guardian is usable.
  #
  # Returns the Stripe Person, or nil when there was nothing to sync.
  def self.sync(user, stripe_account, passphrase:)
    user_compliance_info = user.alive_user_compliance_info
    return unless user_compliance_info&.requires_legal_guardian?

    guardian = user_compliance_info.guardian
    return unless guardian&.has_completed_info?

    # Serialized across the whole lookup-create-adopt sequence, per guardian and account. Two
    # overlapping syncs — account creation racing an update, or two updates — can otherwise both
    # find no Person and both create one, and only the last id written survives locally. The other
    # Person keeps the adult's name, date of birth and address at Stripe with no handle erasure can
    # select on. Deciding by Stripe idempotency key instead would not help: the two calls carry
    # different keys only because neither knows the other exists.
    with_sync_lock(guardian, stripe_account) do
      # Re-read inside the lock: the sync we waited on may have just created the Person and written
      # its id, and this stale copy would otherwise still look unsynced and create a second one.
      guardian.reload

      attributes = person_hash(guardian, user_compliance_info, passphrase:)
      stripe_person = existing_person(stripe_account, guardian)

      if stripe_person
        # Record the id when we reached this Person by the relationship scan rather than by a stored
        # id. Without this the recovery path never writes one back, and erasure — which selects on
        # stripe_person_id — would skip exactly the guardians whose first sync half-failed, leaving
        # the adult's details at Stripe permanently.
        adopt_person_id!(guardian, stripe_person.id) if guardian.stripe_person_id != stripe_person.id

        Stripe::Account.update_person(
          stripe_account.id,
          stripe_person.id,
          StripeMerchantAccountManager.force_utf8_encoding(attributes)
        )
      else
        created = Stripe::Account.create_person(
          stripe_account.id,
          StripeMerchantAccountManager.force_utf8_encoding(attributes)
        )
        adopt_person_id!(guardian, created.id)
        created
      end
    end
  end

  # Holds a Redis lock for the duration of one guardian sync.
  #
  # Raises rather than proceeding when the lock cannot be taken, including when Redis itself is
  # unreachable: both call sites rescue and report, and a missed sync self-heals on the next account
  # update, whereas an unserialized one leaves an untracked Person holding a third party's identity
  # data at Stripe. Failing closed is the cheaper side of that trade.
  def self.with_sync_lock(guardian, stripe_account)
    lock_key = "stripe_guardian_sync:#{stripe_account.id}:#{guardian.id}"
    token = SecureRandom.uuid
    lock_acquired = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SYNC_LOCK_WAIT_TIMEOUT

    until $redis.set(lock_key, token, ex: SYNC_LOCK_TTL.to_i, nx: true)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise SyncLockUnavailable, "Timed out waiting to sync guardian #{guardian.id} to #{stripe_account.id}"
      end

      sleep SYNC_LOCK_RETRY_INTERVAL_SECONDS
    end

    lock_acquired = true
    yield
  ensure
    $redis.eval(SYNC_LOCK_RELEASE_SCRIPT, keys: [lock_key], argv: [token]) if lock_acquired
  end
  private_class_method :with_sync_lock

  # Points this guardian at a Stripe Person, taking the id from whichever other row of the same
  # seller still holds it. stripe_person_id is uniquely indexed, so a replacement guardian adopting
  # the previous guardian's Person would otherwise collide with the superseded row. Scoped to the
  # seller: a cross-user holder means corruption, and the unique index failing loudly beats silently
  # destroying another guardian's only erasure handle.
  def self.adopt_person_id!(guardian, stripe_person_id)
    Guardian.transaction do
      Guardian.where(stripe_person_id:, user_id: guardian.user_id)
              .where.not(id: guardian.id)
              .update_all(stripe_person_id: nil)
      guardian.update!(stripe_person_id:)
    end
  end
  private_class_method :adopt_person_id!

  # Deletes the guardian's Person from Stripe. Called by the erasure path, which is why Guardian
  # keeps stripe_person_id rather than nulling it: the id is the only handle to the copy Stripe
  # holds, and clearing it locally would orphan that copy rather than erase it.
  #
  # The local id is kept after the delete. It is an opaque Stripe handle, not personal data, and
  # keeping it records that a Person existed here and was removed.
  #
  # Takes the account id rather than reading it off the guardian's seller, because the caller is
  # erasure, which has already soft-deleted the account holder by this point — re-deriving it here
  # would depend on which associations still resolve after that.
  #
  # Returns true when Stripe no longer holds the Person.
  def self.delete_person(guardian, stripe_account_id)
    delete_person_by_id(guardian.stripe_person_id, stripe_account_id)
  end

  # Every legal-guardian Person on the account, by recorded id where we have one and by a
  # relationship scan where we do not. A sync that created the Person but failed to save its id
  # leaves no local handle, and erasure cannot wait for the next sync to supply one — the accounts
  # being erased are the least likely to get another.
  def self.stripe_person_ids_for_erasure(guardians, stripe_account_id)
    recorded = guardians.filter_map(&:stripe_person_id)
    return recorded if guardians.none?

    scanned = Stripe::Account.list_persons(
      stripe_account_id,
      relationship: { legal_guardian: true },
      limit: 100
    ).data.map(&:id)

    (recorded + scanned).uniq
  rescue Stripe::StripeError => e
    # The scan is the belt to the recorded id's braces. If Stripe will not answer, delete what we
    # can point at rather than abandoning the erasure entirely.
    ErrorNotifier.notify(e)
    recorded
  end

  # Deletes one Person by id, so erasure can act on a Person found by scan, which has no Guardian
  # row pointing at it.
  def self.delete_person_by_id(stripe_person_id, stripe_account_id)
    return false if stripe_person_id.blank? || stripe_account_id.blank?

    Stripe::Account.delete_person(stripe_account_id, stripe_person_id)
    true
  rescue Stripe::InvalidRequestError => e
    # Already gone on Stripe's side is the outcome we wanted. Anything else is a real failure and
    # must not be swallowed — an undeleted Person means the guardian's details still sit with Stripe
    # after we told the seller they were erased.
    #
    # A missing ACCOUNT is also not a failure: erasure tries every Stripe account the seller ever
    # held, because a locally-deleted account can still hold the Person, and an account Stripe no
    # longer has cannot be holding anything.
    return true if e.message.to_s.include?("No such person")
    return false if e.message.to_s.match?(/No such account|does not exist/i)
    raise
  end

  # Finds the Person this guardian maps to. Prefers the recorded id, since that is unambiguous, and
  # falls back to the relationship flag for a guardian created before the id was stored or by a
  # sync that failed after Stripe had already created the Person.
  def self.existing_person(stripe_account, guardian)
    if guardian.stripe_person_id.present?
      begin
        return Stripe::Account.retrieve_person(stripe_account.id, guardian.stripe_person_id)
      rescue Stripe::InvalidRequestError => e
        # The recorded id no longer resolves — the Person was deleted on Stripe's side. Fall through
        # to the scan, then to creating a fresh one, rather than failing the sync.
        raise unless e.message.to_s.include?("No such person")
      end
    end

    Stripe::Account.list_persons(
      stripe_account.id,
      relationship: { legal_guardian: true },
      limit: 1
    )["data"].first
  end
  private_class_method :existing_person

  # The Stripe Person payload for a guardian.
  #
  # Sends the whole payload every time rather than a diff. Unlike UserComplianceInfo, a Guardian is
  # one mutable row mapping onto one Stripe Person, so there is no previous revision to diff
  # against — which also means none of the representative's dob-must-be-whole special casing
  # applies, since the dob is always sent in full.
  def self.person_hash(guardian, user_compliance_info, passphrase:)
    account_country_code = user_compliance_info.legal_entity_country_code

    hash = {
      first_name: guardian.first_name,
      last_name: guardian.last_name,
      email: guardian.email,
      phone: guardian.phone,
      dob: {
        day: guardian.date_of_birth.day,
        month: guardian.date_of_birth.month,
        year: guardian.date_of_birth.year
      },
      relationship: {
        legal_guardian: true
      },
      address: {
        line1: guardian.street_address,
        line2: nil,
        city: guardian.city,
        state: guardian.state,
        postal_code: StripeMerchantAccountManager.normalize_postal_code(guardian.zip_code, guardian.country_code),
        country: guardian.country_code
      }
    }

    # The guardian accepts Stripe's terms on the account's behalf, which is the whole reason Stripe
    # wants an adult here. additional_tos_acceptances is the guardian-specific channel for that; the
    # account-level tos_acceptance stays with the seller.
    #
    # Gated on the same predicate sync gates on, so the two cannot disagree about what a complete
    # acceptance is. Stripe records this as evidence of where and when a legal acceptance happened,
    # so every field must be one the guardian actually produced — a placeholder date or IP would be
    # a fabricated attestation, which is worse than the account sitting on an unmet requirement.
    if guardian.has_accepted_terms?
      hash[:additional_tos_acceptances] = {
        account: {
          # The date the guardian actually accepted, not now: re-stamping it on every sync would
          # overwrite the real one with the time of an unrelated address edit.
          date: guardian.stripe_tos_accepted_at.to_i,
          ip: guardian.stripe_tos_ip
        }
      }
    end

    apply_tax_id!(hash, guardian, account_country_code, passphrase)

    if StripeBeneficialOwnersManager::COUNTRIES_REQUIRING_NATIONALITY.include?(account_country_code)
      hash[:nationality] = guardian.nationality
    end

    hash.deep_values_strip!
  end

  # Mirrors the representative's rule in StripeMerchantAccountManager.person_hash: Stripe validates
  # the identifier against the account country, so a US account takes a 4-digit ssn_last_4 or a
  # 9-digit id_number and nothing else. Sending a wrongly-sized value fails the whole call, so an
  # identifier that fits neither shape is withheld and Stripe falls back to document verification.
  #
  # ssn_last_4 additionally requires the guardian to be US-resident, matching the representative:
  # a foreign guardian has no SSN, so a short foreign identifier must be withheld rather than
  # mislabelled as one.
  def self.apply_tax_id!(hash, guardian, account_country_code, passphrase)
    tax_id = guardian.individual_tax_id&.decrypt(passphrase)
    return if tax_id.blank?

    if account_country_code == Compliance::Countries::USA.alpha2
      if tax_id.length == US_SSN_LAST_4_LENGTH
        hash[:ssn_last_4] = tax_id if guardian.country_code == Compliance::Countries::USA.alpha2
      elsif tax_id.length == US_FULL_TAX_ID_LENGTH
        hash[:id_number] = tax_id
      end
    else
      hash[:id_number] = tax_id
    end
  end
  private_class_method :apply_tax_id!
end
