# frozen_string_literal: true

# A durable record of every deletion of a product's versions ("variants") and
# their groupings ("variant categories") performed by the product editor or the
# public API.
#
# Why this exists: in July 2026 a production investigation looked at 55
# candidate products whose entire version tree had been soft-deleted and could
# not answer the only question that mattered — did the seller actually ask for
# it? The save path does check that a deletion was explicitly confirmed
# (Product::VariantCategoryUpdaterService.ensure_deletion_intent!), but the list
# of confirmed ids arrives on the request and is never stored, so after the fact
# there is no way to tell a seller-confirmed deletion from one the editor
# submitted on its own. Sentry only receives the deletions that were BLOCKED, so
# the successful ones — the deletions that actually removed data — left no trace
# beyond a `deleted_at` timestamp on the rows themselves.
#
# This table records the successful ones. Rows are written after the deleting
# transaction commits (see `record_deletion`), so a row here always describes
# data that is really gone.
#
# SCOPE: variants and variant categories only. The column names say `variant`
# deliberately rather than pretending to be generic. Extending the audit to
# content pages, files, public files and integrations — the save-contract work in
# gumroad-private#1379 — needs its own columns for those collections; do not
# smuggle them into these. `ROUTES` and `INTENT_SOURCES` are shared vocabulary
# and can grow.
#
# NO PERSONAL DATA. Every column is an id, a count, an enum value, or a
# server-generated correlation digest. Titles, names, emails, descriptions and
# page bodies are deliberately absent, and the schema is FIXED — there is
# intentionally no open-ended metadata blob — so a later change cannot quietly
# start storing seller or buyer content here.
class ProductVariantDeletionAudit < ApplicationRecord
  # Every code path that can soft-delete a variant or a variant category. Keep
  # this exhaustive: an unlisted route is a deletion nobody can see.
  ROUTES = [
    # Product editor save. A category was submitted with no options at all,
    # which the save reads as "remove this whole grouping"
    # (Product::VariantCategoryUpdaterService, the `options.nil?` branch).
    EDITOR_CATEGORY_OMITTED = "editor_category_omitted",
    # Product editor save. The category survived, but some of its versions were
    # absent from the submitted list and so were removed by difference.
    EDITOR_VARIANTS_DIFFED = "editor_variants_diffed",
    # Product editor save. An entire category was missing from the payload and
    # was swept by Product::VariantsUpdaterService after every submitted
    # category had been processed. Distinct from EDITOR_CATEGORY_OMITTED: there
    # the category was present but empty, here it was absent altogether.
    EDITOR_CATEGORY_SWEPT = "editor_category_swept",
    # DELETE /v2/variant_categories/:id — an explicit, single-purpose
    # destructive API call, deliberately outside the editor's guards.
    API_V2_VARIANT_CATEGORY_DESTROY = "api_v2_variant_category_destroy",
  ].freeze

  # How the deletion was authorised.
  INTENT_SOURCES = [
    # Every affected version's id was named in `confirmed_removed_variant_ids`:
    # the editor showed the seller what would be removed and they agreed.
    CONFIRMED_IDS = "confirmed_ids",
    # Nothing affected was explicitly confirmed — the rows went because the
    # payload did not mention them. This is the value worth alerting on: under
    # the save contract proposed in gumroad-private#1379 omission stops meaning
    # deletion, so this should trend to zero.
    PAYLOAD_OMISSION = "payload_omission",
    # Some of the affected versions were confirmed and some were not.
    MIXED = "mixed",
    # A caller asked for exactly this deletion and nothing else.
    API_EXPLICIT_DESTROY = "api_explicit_destroy",
  ].freeze

  belongs_to :product, class_name: "Link", optional: false
  belongs_to :actor_user, class_name: "User", optional: false

  validates :route, presence: true, inclusion: { in: ROUTES }
  validates :intent_source, presence: true, inclusion: { in: INTENT_SOURCES }

  # Records one successful deletion, after the surrounding transaction commits.
  #
  # Three id sets, deliberately kept apart because conflating them is how the
  # intent field ends up lying:
  #
  # - `deleted_variant_external_ids`: versions this request ACTUALLY soft-deleted.
  #   Not what it proposed to delete — a version an earlier save already deleted
  #   must not be attributed to this one.
  # - `affected_variant_external_ids`: versions whose removal this operation
  #   AUTHORISED, which is what intent is judged against. Usually the same as the
  #   deleted set, but not for a category sweep: marking a category deleted
  #   removes the grouping without soft-deleting its rows (no `dependent:` on the
  #   association), so the deleted set is empty while the seller may still have
  #   explicitly confirmed every child. Judging intent from the deleted set there
  #   reports a fully confirmed removal as `payload_omission`.
  # - `confirmed_removed_variant_ids`: the raw confirmation list off the request.
  #   Only its intersection with the affected set is stored, because the list can
  #   name rows this request never touched.
  #
  # Never raises into the caller: a missing audit row is a gap in the trail, not
  # a reason to fail a seller's save.
  def self.record_deletion(
    actor_user_id:,
    product_id:,
    route:,
    deleted_variant_external_ids: [],
    deleted_variant_category_external_ids: [],
    affected_variant_external_ids: nil,
    confirmed_removed_variant_ids: [],
    alive_child_variant_count: 0,
    intent_source: nil,
    revision_token: nil,
    correlation_id: nil
  )
    deleted_variants = Array(deleted_variant_external_ids).compact.uniq
    deleted_categories = Array(deleted_variant_category_external_ids).compact.uniq
    return if deleted_variants.empty? && deleted_categories.empty?

    affected = Array(affected_variant_external_ids || deleted_variant_external_ids).compact.uniq
    confirmed = affected & Array(confirmed_removed_variant_ids).compact
    resolved_intent = intent_source || intent_source_for(affected_external_ids: affected, confirmed_external_ids: confirmed)

    attributes = {
      actor_user_id:,
      product_id:,
      route:,
      intent_source: resolved_intent,
      deleted_variant_external_ids: deleted_variants,
      deleted_variant_category_external_ids: deleted_categories,
      affected_variant_external_ids: affected,
      confirmed_deleted_variant_external_ids: confirmed,
      deleted_variant_count: deleted_variants.size,
      affected_variant_count: affected.size,
      confirmed_deleted_variant_count: confirmed.size,
      unconfirmed_deleted_variant_count: affected.size - confirmed.size,
      alive_child_variant_count:,
      revision_token:,
      correlation_id:,
    }

    # after_commit_everywhere's `after_commit` runs the block immediately when no
    # transaction is open, and on commit when one is. Deferring matters twice
    # over: a row must never describe a deletion that rolled back, and the write
    # must not be able to abort the transaction the seller's save depends on.
    AfterCommitEverywhere.after_commit { safely_create(attributes) }
  rescue StandardError => e
    report_failure(e, "Failed to schedule a product variant deletion audit")
    nil
  end

  # Intent is judged against the versions whose removal was AUTHORISED, not the
  # rows that happened to be soft-deleted.
  def self.intent_source_for(affected_external_ids:, confirmed_external_ids:)
    return PAYLOAD_OMISSION if confirmed_external_ids.empty?
    return CONFIRMED_IDS if confirmed_external_ids.size == affected_external_ids.size

    MIXED
  end

  def self.safely_create(attributes)
    create!(**attributes)
  rescue StandardError => e
    # By the time this runs the deletion is already committed, so raising would
    # only turn a logging failure into an error on a save that succeeded.
    report_failure(e, "Failed to record a product variant deletion audit")
    nil
  end
  private_class_method :safely_create

  # Reporting is best-effort too. If the notifier itself is broken (misconfigured
  # Sentry, a bad argument, a network error) it must not resurrect the exception
  # it was called to swallow — that would defeat the point and break a save that
  # already succeeded. Note `notify` takes keyword context only, never a second
  # positional argument.
  def self.report_failure(exception, message)
    ErrorNotifier.notify(exception, audit_failure: message)
  rescue StandardError
    nil
  end
  private_class_method :report_failure
end
