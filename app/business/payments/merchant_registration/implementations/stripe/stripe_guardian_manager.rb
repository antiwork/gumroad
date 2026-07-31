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

  # Stripe's maximum page size for list_persons. Named because the pagination loop's correctness
  # depends on asking for a full page, not on the number.
  PERSON_PAGE_LIMIT = 100

  # Must outlast the worst case Stripe call, not the typical one. The lock is held across two round
  # trips, and stripe-ruby's 80s read timeout retried max_network_retries times puts one call at up
  # to ~320s — so both together exceed 10 minutes. That worst case is a Stripe brownout, which is
  # exactly when overlapping syncs happen, and a TTL that lapses mid-sequence lets a second sync
  # create the duplicate Person this lock exists to prevent. The only cost of the long TTL is how
  # long a process killed mid-sync blocks the next one, and a missed sync self-heals on the next
  # account update. Pinned against the client's own numbers in the spec, not hardcoded twice.
  #
  # Sizing the lease is the fix here rather than renewing it in a background thread, and that is not
  # a style preference: $redis is a single bare Redis connection shared process-wide
  # (config/redis.rb), not a pool, and it is not thread-safe. A renewer thread interleaves replies on
  # the socket the sync itself is using — verified, a threaded read of the lock key returned nil
  # while the key was demonstrably present. So the renewer would corrupt unrelated Redis reads
  # elsewhere in the process rather than failing where it was added.
  SYNC_LOCK_TTL = 20.minutes
  SYNC_LOCK_WAIT_TIMEOUT = 10.seconds
  SYNC_LOCK_RETRY_INTERVAL_SECONDS = 0.05
  # RedisClient::Error is listed alongside Redis::BaseError because it is not a subclass of it — a
  # connection failure raised by the underlying client escapes a Redis::BaseError rescue. Same pair
  # ProductFile::EXPECTED_ENQUEUE_ERRORS carries.
  REDIS_TRANSPORT_ERRORS = [Redis::BaseError, RedisClient::Error].freeze
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
    # Cheap pre-check so the overwhelming majority of sellers — no guardian requirement at all —
    # never take the lock. Authoritative only inside it: see the re-read below.
    return unless user.alive_user_compliance_info&.requires_legal_guardian?

    # Serialized across the whole lookup-create-adopt-reconcile sequence, per Stripe ACCOUNT. Two
    # overlapping syncs — account creation racing an update, or two updates — can otherwise both
    # find no Person and both create one, and only the last id written survives locally. The other
    # Person keeps the adult's name, date of birth and address at Stripe with no handle erasure can
    # select on. Deciding by Stripe idempotency key instead would not help: the two calls carry
    # different keys only because neither knows the other exists.
    #
    # Keyed on the account and not the guardian because everything under this lock is account-scoped:
    # the relationship scan and the reconcile both see every legal-guardian Person on the account, so
    # two syncs carrying DIFFERENT guardian rows of one seller must still exclude each other. They
    # can — guardian_id is mutable on a live compliance revision, so a request that read the old
    # guardian can overlap one that read the new. Per-guardian locks let the reconcile of one delete
    # the Person the other had just created but not yet recorded.
    with_account_sync_lock(stripe_account.id, "sync guardian for user #{user.id}") do
      # Everything the payload is built from is re-read here, not just the guardian row. We may have
      # waited seconds for the lock, and a compliance update in that window REPLACES the live
      # revision — UpdateUserComplianceInfo soft-deletes the old one and creates a new one — so the
      # pre-lock read can point at a revision that is no longer live. guardian_id is mutable on a
      # live revision too, so the guardian can be swapped without a new revision at all.
      #
      # Reading only the guardian would send Stripe a former guardian's identity data, or a
      # guardian's data after the requirement was dropped (birthday corrected, country changed to
      # one with no guardian path) — an export the current compliance state no longer authorizes.
      # legal_entity_country_code matters for the same reason: it decides how the tax identifier is
      # labelled, so a stale country can mislabel one as an ssn_last_4.
      #
      # Re-deriving the guardian INSIDE the lock is only safe because the lock is keyed on the Stripe
      # account rather than the guardian. A per-guardian lock would be held for the guardian we read
      # before waiting, leaving the one we actually sync unserialized.
      user_compliance_info = user.alive_user_compliance_info
      return unless user_compliance_info&.requires_legal_guardian?

      guardian = user_compliance_info.guardian
      # Also covers erasure: it anonymizes the row and deletes the Persons Stripe holds under this
      # same lock, so a sync that read a complete guardian before that must not put the adult's
      # details back at Stripe with the erasure already finished and reporting success.
      return unless guardian&.has_completed_info?

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
        # A long lease makes expiry rare; it cannot make an orphan impossible. No lock spans the gap
        # between Stripe accepting the create and the id reaching our row — a process killed there
        # leaves a Person holding an adult's details with nothing local pointing at it. So the create
        # is followed by a reconcile: detected after the fact, rather than assumed away.
        reconcile_duplicate_persons!(guardian, stripe_account.id)
        created
      end
    end
  end

  # Deletes legal-guardian Persons on this account that no Guardian row of this seller points at.
  #
  # Such a Person is an adult's name, date of birth, address and tax id sitting at Stripe with no
  # local handle, so erasure's recorded-id path cannot select it. Erasure does also scan by
  # relationship, but only while the seller still has a resolvable Stripe account — so an orphan left
  # in place is PII we may later be unable to reach at all.
  #
  # Scoped by "not referenced locally" rather than "not the one I just created", so it also clears an
  # orphan left by an earlier sync that died between Stripe's create and our write.
  #
  # Never raises: the Person the caller asked for exists and its id is recorded by this point, and
  # failing the sync over the cleanup would turn a resolved duplicate into an unmet Stripe
  # requirement. A leftover is reported and stays reachable by erasure's relationship scan.
  def self.reconcile_duplicate_persons!(guardian, stripe_account_id)
    recorded_ids = Guardian.where(user_id: guardian.user_id).pluck(:stripe_person_id).compact.to_set

    each_legal_guardian_person(stripe_account_id) do |person|
      next if recorded_ids.include?(person.id)

      Stripe::Account.delete_person(stripe_account_id, person.id)
      Rails.logger.info(
        "Deleted orphaned legal-guardian Stripe person for guardian #{guardian.id} on #{stripe_account_id}"
      )
    end
  rescue => e
    ErrorNotifier.notify(e)
  end
  private_class_method :reconcile_duplicate_persons!

  # Every legal-guardian Person on the account, across all pages.
  #
  # Paginated rather than reading one page, because both callers treat what this yields as the
  # COMPLETE set: erasure deletes it and reports the request fulfilled, and the reconcile deletes
  # what it does not find recorded. A Person past the page boundary is therefore not merely missed —
  # it is an adult's name, date of birth, address and tax id that erasure affirmatively reports as
  # gone. `has_more` is read with [] rather than a reader so a page object without the key answers
  # nil instead of raising.
  #
  # Returns false when Stripe said there were more Persons and we could not go get them. That is
  # separate from raising: the pages already yielded are real and the caller still wants them, but it
  # must not read what it got as the whole account.
  def self.each_legal_guardian_person(stripe_account_id, &block)
    starting_after = nil

    loop do
      params = { relationship: { legal_guardian: true }, limit: PERSON_PAGE_LIMIT }
      params[:starting_after] = starting_after if starting_after

      page = Stripe::Account.list_persons(stripe_account_id, params)
      people = page[:data].to_a
      people.each(&block)

      return true unless page[:has_more]

      last_id = people.last&.id
      # Stripe says there is more but gave us no cursor to ask for it. Stopping beats looping on the
      # same page forever, and there are unseen Persons either way, so this is an incomplete scan.
      return false if last_id.nil? || last_id == starting_after

      starting_after = last_id
    end
  end
  private_class_method :each_legal_guardian_person

  # Holds a Redis lock for the duration of one guardian sync, keyed on the Stripe account.
  #
  # Public because erasure takes it too: its Person deletion and a concurrent sync's create are the
  # two writers of legal-guardian Persons on this account, and only holding one lock across both
  # orders them. `description` is for the timeout message — the lock's scope is the account.
  #
  # Raises rather than proceeding when the lock cannot be taken, including when Redis itself is
  # unreachable: both sync call sites rescue and report, and a missed sync self-heals on the next
  # account update, whereas an unserialized one leaves an untracked Person holding a third party's
  # identity data at Stripe. Failing closed is the cheaper side of that trade.
  #
  # A transport error is reported as SyncLockUnavailable rather than escaping as a Redis error,
  # because the callers select on this class to remediate — erasure hands its recorded Persons to
  # the retry job and reports itself incomplete. A raw Redis::BaseError bypasses that and reads as
  # a generic failure, which is the one outcome that leaves a guardian's data at Stripe with
  # nothing retrying it.
  #
  # Release is deliberately NOT translated: by then the protected work has run, so raising would
  # report completed deletes as a lock failure. A lock we could not release just stands until its
  # TTL, which the next sync waits out.
  def self.with_account_sync_lock(stripe_account_id, description)
    lock_key = "stripe_guardian_sync:#{stripe_account_id}"
    token = SecureRandom.uuid
    lock_acquired = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SYNC_LOCK_WAIT_TIMEOUT

    begin
      until $redis.set(lock_key, token, ex: SYNC_LOCK_TTL.to_i, nx: true)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise SyncLockUnavailable, "Timed out waiting to #{description} on #{stripe_account_id}"
        end

        sleep SYNC_LOCK_RETRY_INTERVAL_SECONDS
      end
    rescue *REDIS_TRANSPORT_ERRORS => e
      raise SyncLockUnavailable, "Redis unavailable while waiting to #{description} on #{stripe_account_id}: #{e.message}"
    end

    lock_acquired = true
    yield
  ensure
    if lock_acquired
      begin
        $redis.eval(SYNC_LOCK_RELEASE_SCRIPT, keys: [lock_key], argv: [token])
      rescue *REDIS_TRANSPORT_ERRORS => e
        # Swallowed, not translated: the block already ran, and raising from here would replace its
        # result — or mask its own exception — with a lock error that misdescribes what happened.
        ErrorNotifier.notify(e)
      end
    end
  end

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

  # What an erasure scan of one account found, and whether it saw all of it. `complete` false means
  # the account may still hold legal-guardian Persons this scan never listed, so the caller must not
  # treat deleting `person_ids` as having cleared the account.
  ErasureScan = Struct.new(:person_ids, :complete, keyword_init: true) do
    def complete? = complete
  end

  # Every legal-guardian Person on the account, by recorded id where we have one and by a
  # relationship scan where we do not. A sync that created the Person but failed to save its id
  # leaves no local handle, and erasure cannot wait for the next sync to supply one — the accounts
  # being erased are the least likely to get another.
  def self.stripe_person_ids_for_erasure(guardians, stripe_account_id)
    recorded = guardians.filter_map(&:stripe_person_id)
    return ErasureScan.new(person_ids: recorded, complete: true) if guardians.none?

    scanned = []
    complete = each_legal_guardian_person(stripe_account_id) { |person| scanned << person.id }

    ErasureScan.new(person_ids: (recorded + scanned).uniq, complete:)
  rescue Stripe::StripeError => e
    # The scan is the belt to the recorded id's braces. If Stripe will not answer, delete what we
    # can point at rather than abandoning the erasure entirely.
    #
    # Whatever pages the scan did reach is kept: a partial scan raising on page two still found real
    # Persons on page one, and dropping them would delete fewer than before this rescue existed. But
    # it is reported incomplete — the pages it never reached are exactly where an unrecorded Person
    # hides, so passing the partial set off as the account's contents is how a "successful" erasure
    # leaves guardian PII at Stripe.
    ErrorNotifier.notify(e)
    ErasureScan.new(person_ids: (recorded + scanned.to_a).uniq, complete: false)
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
    # Matched on the structured code rather than the message: a substring hunt that over-matches
    # turns a live failure into a reported-complete erasure, which is the one outcome worth
    # engineering against here. A missing ACCOUNT is also not a failure — erasure tries every Stripe
    # account the seller ever held, and an account Stripe no longer has cannot be holding anything.
    raise unless e.code == "resource_missing"
    return true if e.message.to_s.include?("No such person")
    return false if e.message.to_s.include?("No such account")
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
