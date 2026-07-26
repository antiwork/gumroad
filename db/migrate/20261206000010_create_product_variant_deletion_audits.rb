# frozen_string_literal: true

class CreateProductVariantDeletionAudits < ActiveRecord::Migration[7.1]
  def change
    create_table :product_variant_deletion_audits do |t|
      # Who and what. `actor_user_id` is the signed-in user (or OAuth token
      # owner) whose request deleted the rows — not necessarily the product's
      # owner, since collaborators and admins can also save a product.
      t.bigint :actor_user_id, null: false
      t.bigint :link_id, null: false

      # Which code path performed the deletion. One of the
      # ProductVariantDeletionAudit::ROUTES values — a closed set, so this stays
      # queryable and can't drift into free text.
      t.string :route, null: false

      # How the deletion was authorised. One of
      # ProductVariantDeletionAudit::INTENT_SOURCES. This is the field the July
      # 2026 investigation needed and did not have.
      t.string :intent_source, null: false

      # The rows this request actually soft-deleted, as external ids. "Actually"
      # matters: an earlier save may already have deleted a row the payload also
      # omits, and counting submitted-but-absent ids instead would over-report.
      t.json :deleted_variant_external_ids
      t.json :deleted_variant_category_external_ids

      # The subset of the deleted variants whose ids the editor explicitly
      # confirmed for removal. Stored as the intersection, not as the full
      # confirmed list, because the confirmed list can name rows this request
      # never touched.
      t.json :confirmed_deleted_variant_external_ids

      # Denormalised counts so the common questions ("how much was deleted
      # without explicit confirmation?") are answerable without parsing JSON.
      t.integer :deleted_variant_count, null: false, default: 0
      t.integer :confirmed_deleted_variant_count, null: false, default: 0
      t.integer :unconfirmed_deleted_variant_count, null: false, default: 0

      # Child variants left ALIVE under a category this request deleted.
      # VariantCategory#mark_deleted does not cascade (`has_many :variants` has
      # no `dependent:` option), so the API v2 destroy endpoint can leave live
      # variants parented to a dead category. Recording the count makes that
      # observable instead of something you have to know to look for.
      t.integer :alive_child_variant_count, null: false, default: 0

      # Reserved for the editor-scoped revision token proposed in
      # gumroad-private#1379. That token does not exist yet, so this is always
      # NULL today — the column is here so the audit shape doesn't have to
      # change when the save contract ships.
      t.string :revision_token

      # Correlates an audit row with the Sentry event and the request log for
      # the same save.
      t.string :request_id

      t.datetime :created_at, null: false

      t.index [:link_id, :created_at]
      t.index [:actor_user_id, :created_at]
      t.index [:intent_source, :created_at]
    end
  end
end
