# frozen_string_literal: true

class CreateProductVariantDeletionAudits < ActiveRecord::Migration[7.1]
  def change
    create_table :product_variant_deletion_audits do |t|
      # Who and what. `actor_user_id` is the signed-in user (or OAuth token
      # owner) whose request deleted the rows — not necessarily the product's
      # owner, since collaborators and admins can also save a product.
      t.bigint :actor_user_id, null: false
      t.bigint :product_id, null: false

      # Which code path performed the deletion. One of the
      # ProductVariantDeletionAudit::ROUTES values — a closed set, so this stays
      # queryable and can't drift into free text.
      t.string :route, null: false

      # How the deletion was authorised. One of
      # ProductVariantDeletionAudit::INTENT_SOURCES. This is the field the July
      # 2026 investigation needed and did not have.
      t.string :intent_source, null: false

      # Versions this request ACTUALLY soft-deleted. "Actually" matters: a
      # version an earlier save already deleted must not be attributed to this
      # request, or the record overstates what this save removed.
      t.json :deleted_variant_external_ids

      # Groupings this request marked deleted.
      t.json :deleted_variant_category_external_ids

      # Versions whose removal this operation AUTHORISED — what `intent_source`
      # is judged against. Usually identical to the deleted set, but a category
      # sweep removes the grouping WITHOUT soft-deleting its rows, so the deleted
      # set can be empty while the seller confirmed every child. Judging intent
      # from the deleted set there would report every confirmed sweep as
      # omission-driven.
      t.json :affected_variant_external_ids

      # The subset of the AFFECTED versions whose ids the editor explicitly
      # confirmed for removal. Stored as the intersection, not the full confirmed
      # list, because that list can name rows this request never touched.
      #
      # Named `affected`, not `deleted`, on purpose: for a category sweep the
      # affected versions are still ALIVE (marking a grouping deleted does not
      # cascade), so calling these "deleted" would assert something false about
      # rows that still exist.
      t.json :confirmed_affected_variant_external_ids

      # Denormalised counts so the common questions ("how much was removed
      # without explicit confirmation?") are answerable without parsing JSON.
      t.integer :deleted_variant_count, null: false, default: 0
      t.integer :affected_variant_count, null: false, default: 0
      t.integer :confirmed_affected_variant_count, null: false, default: 0
      t.integer :unconfirmed_affected_variant_count, null: false, default: 0

      # Child versions left ALIVE under a grouping this request deleted.
      # VariantCategory#mark_deleted does not cascade (`has_many :variants` has
      # no `dependent:` option), so both the editor sweep and the API destroy
      # endpoint can leave live versions parented to a deleted grouping.
      # Recording the count makes that observable instead of something you have
      # to know to look for.
      t.integer :alive_child_variant_count, null: false, default: 0

      # Reserved for the editor-scoped revision token proposed in
      # gumroad-private#1379. That token does not exist yet, so this is always
      # NULL today — the column is here so the audit shape doesn't have to change
      # when the save contract ships.
      t.string :revision_token

      # Correlates an audit row with the request that produced it. This is a
      # SERVER-GENERATED digest, never the raw `X-Request-Id`: Rails'
      # ActionDispatch::RequestId accepts that header from the client and only
      # strips punctuation, so storing it verbatim would let a caller write up to
      # 255 chars of chosen text into this table and forge or collide the
      # correlation of other people's audit rows.
      t.string :correlation_id, limit: 64

      t.datetime :created_at, null: false

      t.index [:product_id, :created_at]
      t.index [:actor_user_id, :created_at]
      t.index [:intent_source, :created_at]
    end
  end
end
