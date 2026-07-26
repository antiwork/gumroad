# frozen_string_literal: true

# A durable record of every product-editor or API deletion of a product's
# versions ("variants") and their groupings ("variant categories").
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
# transaction commits, so an audit row always describes data that is really gone
# (see AfterCommitBlock).
#
# NO PERSONAL DATA. Every column is an id, a count, an enum value, or a request
# id. Titles, names, emails, descriptions and page bodies are deliberately
# absent, and the schema is FIXED — there is intentionally no open-ended metadata
# blob — so a later change cannot quietly start storing seller or buyer content
# here.
#
# Scope today is versions and their categories. The save-contract work in
# gumroad-private#1379 extends the same record to content pages, files, public
# files and integrations: add entries to ROUTES (and, if a genuinely new
# authorisation shape appears, INTENT_SOURCES) and reuse `record_deletion`.
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
    # Every deleted version's id was named in `confirmed_removed_variant_ids`:
    # the editor showed the seller what would be removed and they agreed.
    CONFIRMED_IDS = "confirmed_ids",
    # Nothing that was deleted had been explicitly confirmed — the rows went
    # because the payload did not mention them. This is the value worth
    # alerting on: under the save contract proposed in gumroad-private#1379
    # omission stops meaning deletion, so this should trend to zero.
    PAYLOAD_OMISSION = "payload_omission",
    # Some of the deleted versions were confirmed and some were not.
    MIXED = "mixed",
    # A caller asked for exactly this deletion and nothing else.
    API_EXPLICIT_DESTROY = "api_explicit_destroy",
  ].freeze

  belongs_to :link, optional: false
  belongs_to :actor_user, class_name: "User", optional: false

  validates :route, presence: true, inclusion: { in: ROUTES }
  validates :intent_source, presence: true, inclusion: { in: INTENT_SOURCES }

  # Records one successful deletion.
  #
  # `deleted_variant_external_ids` must be the ids this request ACTUALLY
  # soft-deleted, not the ids it proposed to delete. The two differ: a variant
  # the payload omits may already have been deleted by an earlier save, and
  # counting it again would over-report the damage of the current one.
  #
  # `confirmed_removed_variant_ids` is the raw confirmation list off the
  # request. Only its intersection with what was actually deleted is stored,
  # because the list can name rows this request never touched.
  #
  # Never raises into the caller: a missing audit row is a gap in the trail, not
  # a reason to fail a seller's save.
  def self.record_deletion(
    actor_user_id:,
    link_id:,
    route:,
    deleted_variant_external_ids: [],
    deleted_variant_category_external_ids: [],
    confirmed_removed_variant_ids: [],
    alive_child_variant_count: 0,
    intent_source: nil,
    revision_token: nil,
    request_id: nil
  )
    deleted_variants = Array(deleted_variant_external_ids).compact.uniq
    deleted_categories = Array(deleted_variant_category_external_ids).compact.uniq
    return if deleted_variants.empty? && deleted_categories.empty?

    confirmed = deleted_variants & Array(confirmed_removed_variant_ids).compact
    resolved_intent = intent_source || intent_source_for(deleted_external_ids: deleted_variants, confirmed_external_ids: confirmed)

    attributes = {
      actor_user_id:,
      link_id:,
      route:,
      intent_source: resolved_intent,
      deleted_variant_external_ids: deleted_variants,
      deleted_variant_category_external_ids: deleted_categories,
      confirmed_deleted_variant_external_ids: confirmed,
      deleted_variant_count: deleted_variants.size,
      confirmed_deleted_variant_count: confirmed.size,
      unconfirmed_deleted_variant_count: deleted_variants.size - confirmed.size,
      alive_child_variant_count:,
      revision_token:,
      request_id:,
    }

    AfterCommitBlock.run { safely_create(attributes) }
  rescue StandardError => e
    ErrorNotifier.notify(e, "Failed to schedule a product variant deletion audit")
    nil
  end

  # A deletion with no confirmed ids at all was driven purely by what the
  # payload left out; one where every deleted id was confirmed was driven by the
  # seller; anything between is mixed.
  def self.intent_source_for(deleted_external_ids:, confirmed_external_ids:)
    return PAYLOAD_OMISSION if confirmed_external_ids.empty?
    return CONFIRMED_IDS if confirmed_external_ids.size == deleted_external_ids.size

    MIXED
  end

  def self.safely_create(attributes)
    create!(**attributes)
  rescue StandardError => e
    # By the time this runs the deletion is already committed, so raising would
    # only turn a logging failure into an error on a save that succeeded.
    ErrorNotifier.notify(e, "Failed to record a product variant deletion audit")
    nil
  end
  private_class_method :safely_create
end
