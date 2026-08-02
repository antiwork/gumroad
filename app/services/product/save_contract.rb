# frozen_string_literal: true

# The product editor's save contract (gumroad-private#1379).
#
# The editor save is a full-snapshot PUT, and every collection was read as
# `params[:thing] || []`. That collapses three different requests into one:
# "the seller emptied this", "this request isn't about this collection", and
# "the value was malformed, so strong parameters dropped it and it arrives
# absent". All three read as `[]`, and `[]` meant "delete everything alive" —
# so a client bug or a proxy that mangles a field became permanent data loss.
# Two collections have no undo: `integrations` calls `integration.disconnect!`
# against the provider, and `public_files` strips `<public-file-embed>` nodes
# out of the seller's description in the same pass.
#
#   Rule 1  absent == [] == "no changes", uniformly across all five
#           collections. Neither deletes anything, ever.
#   Rule 2  deletion only through an explicit operation — a list of ids or a
#           clear-all, both tied to the editor revision the client loaded.
#   Rule 3  API v2 semantics unchanged; this is consulted only from the
#           editor's save path.
#
# Rule 1 gives up emptying a collection by sending `[]`. That is a
# client-visible change, and it is the point.
#
# The collections disagree about shape (`integrations` is a hash keyed by
# provider name, the rest are arrays) and about where deletion happens, so the
# payload is wrapped once on entry and every collection asks the same question.
class Product::SaveContract
  # A destructive save arrived without a current snapshot token. Distinct from
  # StaleContentWriteGuard's conflict — that one is about overwriting an edit,
  # this one about removing rows the session may never have seen — so the two
  # are reported separately.
  class StaleDeletionConflict < StandardError
    def message
      "This page is out of date, so the items you removed were not deleted. " \
        "Reload to see the current version and try again."
    end
  end

  # One response mapping cannot represent the same submitted page id creating
  # or updating more than one stored row. Accepting that payload would make the
  # editor point both references at whichever row won the mapping, then create
  # more duplicate pages on later saves.
  class AmbiguousRichContentIdConflict < StandardError
    def message
      "This save references the same content page more than once, so it cannot be applied safely. " \
        "Reload the editor and try again."
    end
  end

  # The five collections the editor save can destroy. Listed rather than
  # inferred so adding a sixth is deliberate.
  COLLECTIONS = %i[rich_content variants files public_files integrations].freeze

  # `deleted_ids[:variants]` carries VERSION ids only — never VariantCategory
  # (grouping) ids. An external id is `ObfuscateIds.encrypt(primary_key)` with no
  # table discriminator, and `variants`/`variant_categories` have independent
  # auto-increment counters, so a version and a grouping can share one id string.
  # The deletion paths in Product::VariantCategoryUpdaterService resolve these ids
  # against versions with no collision check, which is correct only while this
  # holds. Put a grouping id in here and that grouping's colliding VERSION is what
  # disappears, while the grouping survives and the save reports 200.
  #
  # Enforced by spec/services/product/variant_deleted_ids_kind_invariant_spec.rb.
  # A grouping goes away as a consequence of losing its last version, not by being
  # named — if you add grouping-level deletion, give it its own collection.

  # Kill switch, default OFF: with the flag inactive every collection reports
  # `submitted?` exactly as the old code did (absent/[] still reaches the
  # diff-and-delete paths), so flipping it either way is a pure revert.
  #
  # Deliberately NOT a compatibility shim: with the flag ON, `[]` never deletes.
  # Keeping "`[]` still empties, for now" would preserve the exact ambiguity
  # this contract exists to remove.
  FEATURE_NAME = :product_editor_save_contract

  # Deletion operations the client can send; neither can be produced by omitting
  # something. `deleted_ids` removes exactly those; `cleared_collections`
  # removes everything alive, deliberately noisier than sending `[]`.
  DELETION_OPERATIONS = :deletion_operations

  # A save with no revision predates the contract: it may still write, but it
  # may not delete. See `#may_delete?`.
  REVISION_KEY = :editor_revision

  attr_reader :params, :product

  def initialize(params:, product:)
    @params = params || ActionController::Parameters.new
    @product = product
    # The fingerprint costs five COUNT/ordering queries against the product's
    # children, and with the flag off nothing can consume the answer.
    #
    # When enabled it must be answered eagerly, before any write: the save
    # mutates rows as it runs, so a lazy check would compare the client's token
    # against state this request itself changed, silently dropping a legitimate
    # deletion submitted alongside a new page. Callers construct this first.
    may_delete? if enforced?
  end

  # Read once per save and passed down, so a flag flipped mid-request cannot
  # make one collection follow the new rules and another the old ones.
  #
  # The flag store is Redis-backed and this runs while the product row is
  # locked, so a lookup failure must neither raise nor answer "disabled":
  # "disabled" routes the save down the legacy delete-by-omission path, so a
  # Redis blip would wipe every collection the payload didn't mention. A failed
  # lookup is therefore neither enabled nor disabled — see `#degraded?`. The
  # contract stays off (no token gating, no 409s for legacy clients) but
  # implicit deletion is suppressed for the rest of the save.
  def enforced?
    return @enforced if defined?(@enforced)

    @enforced = resolve_enforced
  end

  # Did the flag lookup itself fail? Distinct from "the flag is off", which is a
  # real answer meaning "behave exactly as main does today". Degraded means we
  # do not know, and the only safe reading is that nothing may be deleted
  # implicitly.
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

  # Bugsnag reaches over the network from inside a locked, mid-transaction save,
  # so it gets the same treatment as the lookup it is reporting on.
  private def report_lookup_failure(error)
    ErrorNotifier.notify(error, product_id: product&.id, context: "Product::SaveContract flag lookup")
  rescue StandardError
    nil
  end

  # Did this request actually submit this collection? The whole contract in one
  # method: `false` means leave the collection exactly as the server has it —
  # not empty it, not diff it, not touch it.
  #
  # Absent and `[]` both answer `false` (Rule 1). They are distinguishable via
  # `params.key?` and that is deliberately discarded: otherwise a malformed
  # value, which strong parameters drops to absent, would behave differently
  # from the same value sent correctly as `[]`.
  def submitted?(collection)
    assert_known!(collection)
    return true unless enforced?

    params[collection].present?
  end

  # Did this save ask to remove anything at all? Deliberately independent of
  # whether the removal is ALLOWED, so the caller can tell a stale destructive
  # save (refuse loudly) from a stale write-only save (let it through).
  def requested_deletion?
    return false unless enforced?

    COLLECTIONS.any? { |collection| raw_cleared?(collection) || raw_deleted_ids(collection).any? } ||
      requested_variant_deletion?
  end

  # Ids the client explicitly asked to delete. Never inferred from a diff —
  # that inference is what let an omitted collection read as an intentional wipe.
  #
  # Malformed shapes degrade to "no explicit deletions" rather than raise: this
  # runs inside the seller's save, so an exception turns a client bug into a
  # failed save. A bare String, Array, Integer and `{deleted_ids: "not-a-hash"}`
  # all reach here in practice, and `String#dig` does not exist.
  def deleted_ids(collection)
    return [] unless enforced?
    return [] unless may_delete?

    raw_deleted_ids(collection)
  rescue StandardError
    []
  end

  # What the client ASKED to delete, before freshness is applied. Kept separate
  # from `deleted_ids` ("what may actually be deleted") because reading intent
  # through the allowed-ids accessor makes a stale destructive save look
  # identical to a save with no deletions in it.
  def raw_deleted_ids(collection)
    return [] unless enforced?

    assert_known!(collection)
    ids = deletion_operations[:deleted_ids]
    return [] unless ids.respond_to?(:dig)

    Array(ids[collection.to_sym]).map(&:to_s).uniq.reject(&:blank?)
  rescue StandardError
    []
  end

  # Ids to delete from a collection owned by ONE version rather than by the
  # product. Version-level integrations are the case: they live on a
  # variant/integration join, so a flat `deleted_ids[:integrations]` cannot say
  # "disconnect discord from version A but leave it on version B". Nested under
  # the owner's external id:
  #
  #   deletion_operations: {
  #     variant_deleted_ids: { "<variant_external_id>": { integrations: ["discord"] } }
  #   }
  def variant_deleted_ids(owner_external_id, collection)
    return [] unless enforced?
    return [] unless may_delete?

    raw_variant_deleted_ids(owner_external_id, collection)
  rescue StandardError
    []
  end

  # What was REQUESTED for a version-scoped collection, before freshness is
  # considered. Mirrors raw_deleted_ids; see the comment there for why the
  # requested/allowed split matters.
  def raw_variant_deleted_ids(owner_external_id, collection)
    return [] unless enforced?

    assert_known!(collection)
    return [] if owner_external_id.blank?

    by_owner = deletion_operations[:variant_deleted_ids]
    return [] unless by_owner.respond_to?(:dig)

    scoped = by_owner[owner_external_id.to_s] || by_owner[owner_external_id.to_sym]
    return [] unless scoped.respond_to?(:dig)

    Array(scoped[collection.to_sym] || scoped[collection.to_s]).map(&:to_s).uniq.reject(&:blank?)
  rescue StandardError
    []
  end

  # External ids of the versions this save is allowed to remove something from.
  # Needed BEFORE deciding which variant groupings to visit: a version-scoped
  # deletion names its owner directly, so it can point at a version in a
  # grouping the editor never renders — which the save would otherwise skip,
  # return success, and leave the integration connected.
  def variant_deletion_owner_ids
    return [] unless enforced?
    return [] unless may_delete?

    by_owner = deletion_operations[:variant_deleted_ids]
    return [] unless by_owner.respond_to?(:each_pair)

    by_owner.each_pair.filter_map do |owner_id, _scoped|
      owner_id.to_s if COLLECTIONS.any? { |collection| raw_variant_deleted_ids(owner_id, collection).any? }
    end
  rescue StandardError
    []
  end

  # Did the client ask to remove anything from any version-scoped collection?
  # Folded into requested_deletion? so a version-scoped removal is treated as a
  # destructive save for staleness purposes, exactly like a product-level one.
  def requested_variant_deletion?
    return false unless enforced?

    by_owner = deletion_operations[:variant_deleted_ids]
    return false unless by_owner.respond_to?(:each_pair)

    by_owner.each_pair.any? do |owner_id, _scoped|
      COLLECTIONS.any? { |collection| raw_variant_deleted_ids(owner_id, collection).any? }
    end
  rescue StandardError
    false
  end

  # The only route to "delete everything", and a positive statement tied to a
  # revision rather than the absence of one.
  #
  # Deliberately strict: a bare string ("variants" rather than ["variants"]) is
  # NOT a clear-all, because Array() would wrap it and turn a malformed payload
  # into an instruction to empty the collection.
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

  # Deleting requires the client to name the snapshot it edited AND that
  # snapshot to still have been current when the save began. Otherwise the save
  # is write-only. This is the two-tabs case: tab A loads, tab B saves, tab A
  # submits a payload describing a product that no longer exists.
  #
  # Deliberately narrower than rejecting the whole save — product-wide
  # optimistic concurrency was tried and had to be switched off for blocking
  # legitimate work. A stale tab fixing a typo is recoverable; one deleting a
  # page is not, so only the deletion is refused.
  #
  # CRITICAL: evaluated ONCE, at construction, before any mutation, and
  # memoized. Every write during the save moves the product's fingerprint, so
  # re-computing later would compare the client's token against a snapshot this
  # request itself had already moved, silently dropping a legitimate deletion.
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
