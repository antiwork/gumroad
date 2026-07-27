# frozen_string_literal: true

# The product editor's save contract (gumroad-private#1379).
#
# ## The defect this exists to remove
#
# The editor save is a full-snapshot PUT. Every collection in it was read as
# `params[:thing] || []`, which makes three very different situations
# indistinguishable:
#
#   1. "the seller emptied this collection"        -> [] on purpose
#   2. "this request isn't about that collection"  -> key absent
#   3. "the value was malformed"                   -> strong parameters DROPPED
#      it, so it arrives absent — `files: "not-a-list"` never reaches the
#      permit list's array-of-hashes shape and is silently discarded
#
# All three collapsed to `[]`, and `[]` meant "delete everything alive". Case 3
# is the dangerous one: a client bug, a truncated request body, or a proxy that
# mangles a field turns into permanent data loss with no error anywhere. Two of
# the five collections had no deletion guard at all, and their failure modes are
# not soft:
#
#   * `integrations` calls `integration.disconnect!` — a live call to the
#     third-party provider. There is no undo.
#   * `public_files` strips `<public-file-embed>` nodes out of the seller's
#     description in the same pass that schedules the files, so the description
#     is damaged immediately even though the rows survive ten days.
#
# ## The contract
#
# Per the approved ruling on gumroad-private#1379:
#
#   Rule 1  absent == [] == "no changes". Uniformly, across all five
#           collections. Neither one deletes anything, ever.
#   Rule 2  deletion happens only through an explicit operation: a list of ids
#           to delete, or an explicit clear-all — both tied to the editor
#           revision the client loaded.
#   Rule 3  API v2 semantics are unchanged. This module is only consulted from
#           the editor's save path.
#
# Note what Rule 1 gives up on purpose: a client can no longer empty a
# collection by sending `[]`. That is a client-visible change, and it is the
# point — emptying is now something you have to ask for, and asking is
# recorded.
#
# ## Why this is a value object rather than a pile of `if`s in the controller
#
# The five collections disagree about shape (`integrations` is a hash keyed by
# provider name; the rest are arrays), about where deletion happens (four
# services and one inline block), and about which guard already protects them.
# Wrapping the payload once, at the point it enters the save, means every
# collection asks the same question — "did this request submit you?" — and
# gets an answer that does not depend on the caller remembering to check.
class Product::SaveContract
  # A destructive save arrived without a current snapshot token.
  #
  # Distinct from StaleContentWriteGuard's conflict: that one is about
  # overwriting an edit, this one is about removing rows the session may never
  # have seen. They are reported separately so the editor can say something
  # accurate, and so the two can be measured independently during rollout.
  class StaleDeletionConflict < StandardError
    def message
      "This page is out of date, so the items you removed were not deleted. " \
        "Reload to see the current version and try again."
    end
  end

  # The five collections the editor save can destroy. Named here rather than
  # inferred so that adding a sixth is a deliberate act with a test attached.
  COLLECTIONS = %i[rich_content variants files public_files integrations].freeze

  # Kill switch. Defaults OFF: with the flag inactive every collection reports
  # `submitted?` exactly as the old code behaved (absent/[] still reaches the
  # existing diff-and-delete paths), so enabling and disabling this is a pure
  # revert with no migration and no data to unwind.
  #
  # Rolled out per-seller with `Feature.activate_user(:product_editor_save_contract, user)`
  # and killed globally with `Feature.deactivate(:product_editor_save_contract)`.
  #
  # Deliberately NOT a compatibility shim: when the flag is ON, `[]` never
  # deletes, full stop. A shim that kept "`[]` still empties, for now" would
  # preserve the exact ambiguity this contract exists to remove, and would have
  # to be removed later by someone who no longer remembers why it was there.
  FEATURE_NAME = :product_editor_save_contract

  # Deletion operations the client can send. Both are explicit; neither can be
  # produced by omitting something.
  #
  #   deleted_ids        — remove exactly these, nothing else
  #   cleared_collections — remove everything alive in these collections
  #
  # `cleared_collections` exists because "the seller really did empty this"
  # has to remain expressible. It is deliberately noisier than sending `[]`.
  DELETION_OPERATIONS = :deletion_operations

  # A save is only allowed to delete when it proves which snapshot it was built
  # from. Absent revision means the client predates the contract; such a save
  # may still write, but it may not delete. See `#may_delete?`.
  REVISION_KEY = :editor_revision

  attr_reader :params, :product

  def initialize(params:, product:)
    @params = params || ActionController::Parameters.new
    @product = product
    # Do no revision work at all when the contract is disabled. Computing the
    # fingerprint means five COUNT/ordering queries against the product's
    # children, and with the flag off nothing can consume the answer — so on the
    # default path this must cost nothing beyond one flag lookup.
    #
    # When enabled, answer the freshness question eagerly rather than lazily.
    # The save mutates rows as it runs, so by the time a deletion step asks "may
    # I delete?", the product's fingerprint has already moved and a lazy check
    # would compare the client's token against state the request itself changed
    # — silently dropping a legitimate deletion submitted alongside a new page.
    # Callers construct this before any write.
    may_delete? if enforced?
  end

  # Is the contract enforced for this save?
  #
  # Read once per save and passed down rather than re-checked at each call
  # site, so a flag flipped mid-request cannot make one collection follow the
  # new rules and another the old ones.
  #
  # The flag store is Redis-backed (config/initializers/feature_toggle.rb) and
  # this runs while the product row is locked, so a Redis outage must not raise
  # through the seller's save.
  #
  # It must also not answer "disabled", which is what an earlier version of this
  # did. "Disabled" routes the save down the legacy path, and the legacy path
  # deletes by omission — so a Redis blip would have turned an ordinary save
  # into a wipe of every collection the payload happened not to mention. That is
  # the exact failure this PR exists to prevent, reintroduced through the error
  # handler.
  #
  # So a failed lookup is neither enabled nor disabled: see `#degraded?`. The
  # contract stays off (no token gating, no 409s for clients that never sent a
  # token), but implicit deletion is suppressed for the duration of the save.
  def enforced?
    return @enforced if defined?(@enforced)

    @enforced = resolve_enforced
  end

  # Did the flag lookup itself fail?
  #
  # Distinct from "the flag is off". Off is a real answer and means "behave
  # exactly as main does today". Degraded means we do not know, and the only
  # safe reading of "we do not know" is that nothing may be deleted implicitly:
  # the request never asked for a deletion, so not deleting cannot lose data,
  # while deleting on a guess can and did.
  def degraded?
    enforced? unless defined?(@enforced)

    @degraded
  end

  # May this save remove rows the payload simply didn't mention?
  #
  # The legacy paths ask this before their diff-and-delete. It is the one
  # question a flag-store outage has to answer conservatively.
  def implicit_deletion_allowed?
    !degraded?
  end

  private def resolve_enforced
    @degraded = false
    product.present? && Feature.active?(FEATURE_NAME, product.user)
  rescue StandardError => e
    @degraded = true
    report_lookup_failure(e)
    false
  end

  # Reporting must never be the thing that breaks a seller's save. The notifier
  # reaches out over the network (Bugsnag) from inside a locked, mid-transaction
  # save, so it gets the same treatment as the lookup it is reporting on.
  private def report_lookup_failure(error)
    ErrorNotifier.notify(error, product_id: product&.id, context: "Product::SaveContract flag lookup")
  rescue StandardError
    nil
  end

  # Did this request actually submit this collection?
  #
  # This is the whole contract in one method. `false` means the save must leave
  # the collection exactly as the server has it — not empty it, not diff it,
  # not touch it.
  #
  # Absent and `[]` both answer `false`, which is Rule 1. They are
  # distinguishable at the HTTP layer (`params.key?`) and the distinction is
  # deliberately discarded: relying on it would mean a malformed value — which
  # strong parameters drops, making it absent — behaves differently from the
  # same value sent correctly as `[]`, and that difference is exactly the bug.
  #
  # With the flag off this always answers `true`, so callers fall through to
  # their existing behaviour unchanged.
  def submitted?(collection)
    assert_known!(collection)
    return true unless enforced?

    params[collection].present?
  end

  # Did this save ask to remove anything at all, in any collection?
  #
  # Deliberately independent of whether the removal is ALLOWED: this answers
  # "was destruction requested", so the caller can tell a stale destructive
  # save (refuse, loudly) from a stale write-only save (let it through).
  def requested_deletion?
    return false unless enforced?

    COLLECTIONS.any? { |collection| raw_cleared?(collection) || raw_deleted_ids(collection).any? }
  end

  # Ids the client explicitly asked to delete from this collection.
  #
  # Empty unless the client sent them. Never inferred from a diff — that
  # inference is what let an omitted collection read as an intentional wipe.
  #
  # Every malformed shape has to degrade to "no explicit deletions" rather than
  # raise: this runs inside the seller's save, so an exception here turns a
  # client bug into a failed save. Verified by probe that the shapes reaching
  # this method include a bare String, an Array, an Integer, and
  # `{deleted_ids: "not-a-hash"}` — the last of which raised TypeError from
  # `dig` until this was hardened, because `String#dig` does not exist.
  def deleted_ids(collection)
    return [] unless enforced?
    return [] unless may_delete?

    raw_deleted_ids(collection)
  rescue StandardError
    []
  end

  # What the client ASKED to delete, before the freshness question is applied.
  #
  # Kept separate from `deleted_ids` so the two questions never get conflated:
  # this one is "what was requested" (used to detect a destructive save that
  # must be refused outright), while `deleted_ids` is "what may actually be
  # deleted". Reading requested intent through the allowed-ids accessor would
  # make a stale destructive save look identical to a save with no deletions in
  # it, which is exactly the silent-success bug.
  def raw_deleted_ids(collection)
    return [] unless enforced?

    assert_known!(collection)
    ids = deletion_operations[:deleted_ids]
    return [] unless ids.respond_to?(:dig)

    Array(ids[collection.to_sym]).map(&:to_s).uniq.reject(&:blank?)
  rescue StandardError
    []
  end

  # Did the client explicitly ask to empty this collection?
  #
  # This is the only route to "delete everything", and it is a positive
  # statement tied to a revision — not the absence of one.
  #
  # Note the deliberate strictness: a bare string ("variants" rather than
  # ["variants"]) is NOT accepted as a clear-all. Array() would happily wrap it
  # and turn a malformed payload into an instruction to empty the collection,
  # which is precisely the class of accident this contract exists to prevent.
  def cleared?(collection)
    return false unless enforced?
    return false unless may_delete?

    raw_cleared?(collection)
  rescue StandardError
    false
  end

  # As `cleared?`, but ignoring freshness — see `raw_deleted_ids`.
  def raw_cleared?(collection)
    return false unless enforced?

    assert_known!(collection)
    cleared = deletion_operations[:cleared_collections]
    return false unless cleared.is_a?(Array)

    cleared.map(&:to_s).include?(collection.to_s)
  rescue StandardError
    false
  end

  # Any deletion at all requires the client to say which snapshot it was
  # editing, AND that snapshot must still have been current when the save
  # began. A save with no revision, or one built from a snapshot that had
  # already moved, is treated as write-only: it can create and update, but it
  # cannot remove anything.
  #
  # This is what stops a stale tab from deleting rows it never knew about — the
  # two-tabs case where tab A loads, tab B saves, and tab A then submits a
  # payload describing a product that no longer exists.
  #
  # It is deliberately narrower than rejecting the whole save. An earlier
  # attempt (product-wide optimistic concurrency) rejected any save built on a
  # changed product and had to be switched off for blocking legitimate work. A
  # stale tab fixing a typo is recoverable; a stale tab deleting a page is not,
  # so only the deletion is refused.
  #
  # CRITICAL: this is evaluated ONCE, against the state at construction time,
  # and memoized. The save mutates rows as it goes — it creates content pages
  # before it reaches the variant deletion step — and every one of those writes
  # changes the product's fingerprint. Re-computing freshness later in the same
  # request would therefore compare the client's token against a snapshot the
  # request itself had already moved, and a perfectly legitimate deletion
  # submitted alongside a new page would be silently dropped. The contract is
  # built at the top of the save, before any mutation, precisely so this
  # question is answered about the state the client actually edited.
  def may_delete?
    return @may_delete if defined?(@may_delete)

    @may_delete =
      if editor_revision.blank? || product.blank?
        false
      else
        Product::EditorRevision.fresh?(product:, token: editor_revision)
      end
  end

  # The snapshot identifier the editor loaded. Compared per-record by
  # Product::EditorRevision to decide whether a specific row moved underneath
  # this session.
  def editor_revision
    params[REVISION_KEY].presence
  end

  # True when the client understands the contract at all. Used only for
  # reporting: a legacy client is not an error, it just cannot delete.
  def contract_aware?
    params.key?(REVISION_KEY) || params.key?(DELETION_OPERATIONS)
  end

  private
    def deletion_operations
      @deletion_operations ||= begin
        ops = params[DELETION_OPERATIONS]
        ops.respond_to?(:to_unsafe_h) ? ops.to_unsafe_h.symbolize_keys : (ops || {}).symbolize_keys
      end
    rescue StandardError
      # A malformed deletion_operations block must not raise mid-save. It means
      # "no explicit deletions were legible", which under Rule 1 is the safe
      # reading: nothing gets deleted.
      {}
    end

    def assert_known!(collection)
      return if COLLECTIONS.include?(collection.to_sym)

      raise ArgumentError, "Unknown save-contract collection: #{collection.inspect}"
    end
end
