# frozen_string_literal: true

# The editor revision token (gumroad-private#1379, Rule 4).
#
# ## What problem this actually solves
#
# Two tabs open on the same product. Tab A loads, tab B loads, tab B saves,
# then tab A saves. Tab A's payload describes a product that no longer exists:
# rows B created are unknown to it, and rows B edited look, from A's point of
# view, unchanged. Under the old full-snapshot save, A's view silently won.
#
# `Product::StaleContentWriteGuard` already detects part of this, but it works
# on per-record timestamps echoed by the client and its seller-visible
# rejection is switched off by default because it blocked legitimate saves
# (see that class's comment, and #6245 -> #6311). Product-wide optimistic
# concurrency was too blunt: any concurrent change anywhere on the product
# rejected the whole save.
#
# The revision token is deliberately narrower. It answers one question:
#
#   "was this save built from the snapshot the server currently holds?"
#
# and it is consulted ONLY to decide whether a *deletion* is allowed to
# proceed. Writes are not gated on it. That asymmetry is the entire design:
# a stale tab overwriting a title is annoying and recoverable; a stale tab
# deleting a page or disconnecting an integration is not.
#
# ## Why a token instead of comparing timestamps again
#
# Timestamps are per-record and client-supplied, so the client decides what to
# echo — and a client that omits a record entirely echoes nothing, which is
# exactly the omission case the contract exists to neutralise. A single token
# covering the product's deletable state cannot be silently omitted: it is
# either present and current, present and stale, or absent, and all three have
# defined behaviour.
#
# ## What the token is
#
# A digest over the identity and liveness of everything the editor can delete:
# the alive ids of all five collections, plus the handful of product columns
# that change what a save is allowed to delete.
# Deliberately NOT a timestamp — a digest changes only when something the
# contract cares about changes, so an unrelated write (a price edit, a tag) does
# not invalidate a seller's in-flight deletion and produce the false conflicts
# that killed #6245.
class Product::EditorRevision
  # Bumping this invalidates every outstanding token. Do that when the set of
  # things the digest covers changes, so an old token cannot be read as current
  # against a new definition.
  #
  # v2: each collection now contributes updated_at as well as id, so edits to
  # existing children move the token and not just additions and removals.
  # v3: the product's own updated_at is no longer part of the digest. It made
  # every product write invalidate outstanding deletions — a price or tag edit
  # bumps updated_at, which is precisely the false-conflict behaviour this class
  # documents itself as avoiding. Replaced by the named columns in
  # DELETION_RELEVANT_ATTRIBUTES.
  VERSION = "v3"

  # Product attributes that change WHAT A SAVE MAY DELETE, and therefore have
  # to be witnessed by the token. This is deliberately a short allowlist rather
  # than `updated_at`: everything absent from it (price, name, tags,
  # description, visibility, …) can be edited by a co-editor without
  # invalidating a stale tab's in-flight deletion, because none of it changes
  # which rows that deletion would remove.
  #
  # - has_same_rich_content_for_all_variants: decides whether version-level
  #   pages are even visible to the editor. Product::RichContentDeletionGuard
  #   branches on the PERSISTED value to classify a page deletion, and a save
  #   built while it was off means something different once it is on — this is
  #   the July 21 wipe mechanism in that guard's comment.
  # - is_tiered_membership: selects the variant deletion route, and decides
  #   whether tier-level recurring prices are swept alongside a version.
  DELETION_RELEVANT_ATTRIBUTES = %w[
    has_same_rich_content_for_all_variants
    is_tiered_membership
  ].freeze


  class << self
    # The token for the product's current committed state.
    def current(product)
      digest(fingerprint(product))
    end

    # Was this save built from the current snapshot?
    #
    # A blank token is NOT fresh. That is the whole point: a client that cannot
    # say which snapshot it holds does not get to delete. It can still write.
    def fresh?(product:, token:)
      return false if token.blank?

      ActiveSupport::SecurityUtils.secure_compare(token.to_s, current(product))
    end

    private
      # Everything the editor is able to destroy, in a stable order.
      #
      # Ordering matters: `pluck` without an explicit order can return rows in
      # a different sequence between calls, which would make the digest differ
      # for identical state and reject saves at random — a failure mode that
      # would look exactly like the #6245 regression.
      #
      # Each collection contributes both id AND updated_at. Identity alone is
      # not enough: if tab B renames a version and tab A then deletes it, an
      # id-only digest is unchanged, so tab A's token still looks current and
      # the deletion proceeds against a row the seller has since edited — the
      # edit is destroyed with no warning. Including updated_at makes any edit
      # to a deletable child move the token, so the stale tab is told to reload.
      #
      # This deliberately does not extend to non-deletable state (a price, a
      # tag): those still must not invalidate an in-flight deletion, which is
      # the false-conflict problem that killed #6245. That is why the product
      # contributes only DELETION_RELEVANT_COLUMNS and not its updated_at.
      def fingerprint(product)
        {
          version: VERSION,
          product: product.id,
          product_state: product_state(product),
          rich_content: stamped(product.alive_rich_contents),
          variants: alive_variant_stamps(product),
          variant_categories: stamped(product.variant_categories.alive),
          files: stamped(product.product_files.alive),
          public_files: stamped(product.alive_public_files),
          integrations: stamped(product.active_integrations),
          # Version-level integration joins (gumroad-private#1379). Without
          # these the token cannot witness an integration enabled on a version
          # by another tab: the join row is what changes, and neither the
          # product's own integrations nor the variant's updated_at moves when
          # it is created. A stale tab could then remove an integration a
          # co-editor had just enabled, and the deletion would look fresh.
          variant_integrations: variant_integration_stamps(product),
        }
      end

      # The deletion-relevant product attributes, read straight off the record.
      #
      # These are `flags` bits (flag_shih_tzu) rather than real columns, so the
      # existence check is on the reader, not on column_names. Raises if one
      # stops existing: a rename that silently dropped an attribute here would
      # quietly widen what a stale token is willing to delete, which is the
      # failure mode this class exists to prevent — better a loud failure.
      def product_state(product)
        DELETION_RELEVANT_ATTRIBUTES.index_with do |attribute|
          unless product.respond_to?(attribute)
            raise ArgumentError, "Product::EditorRevision: no such attribute #{attribute.inspect}"
          end

          # Normalise to a boolean: flag_shih_tzu readers return nil for unset
          # bits and true once set, and nil vs false must not move the digest.
          !!product.public_send(attribute)
        end
      end

      # [variant_id, integration_id] pairs for every live version-level join, in
      # a stable order. Ids alone are the right witness here: the join carries
      # no state of its own beyond existing, and it is created and soft-deleted
      # rather than edited.
      def variant_integration_stamps(product)
        BaseVariantIntegration
          .alive
          .joins(:base_variant)
          .where(base_variants: { id: product.base_variants.select(:id) })
          .order(:base_variant_id, :integration_id)
          .pluck(:base_variant_id, :integration_id)
      end

      # [id, stamp] pairs in a stable order, where the stamp changes whenever
      # the row is edited.
      #
      # `updated_at` alone is not sufficient everywhere. Probed against the real
      # schema: `rich_contents` and `product_files` store datetime(6), but
      # `base_variants` stores plain `datetime` at SECOND precision, so renaming
      # a version in the same second it was created leaves updated_at
      # unchanged — and "tab B edits, tab A deletes" is exactly a same-second
      # race. `variant_categories` has no timestamp columns at all.
      #
      # So: use updated_at where it is precise enough to be a witness, and fall
      # back to digesting the row's own columns where it is not. The fallback is
      # only reached for small collections (a product's versions and their
      # categories), and it is the honest option — the alternative is a token
      # that silently fails to notice the edit it exists to notice.
      def stamped(relation)
        columns = relation.klass.column_names
        return row_digests(relation, columns) unless precise_timestamp?(relation, columns)

        relation.order(:id).pluck(:id, :updated_at).map { |id, at| [id, at&.to_fs(:usec)] }
      end

      def precise_timestamp?(relation, columns)
        return false unless columns.include?("updated_at")

        column = relation.klass.columns_hash["updated_at"]
        column.precision.to_i.positive?
      end

      # A digest per row over everything except the timestamps themselves, so
      # any edit to any field moves the token regardless of clock granularity.
      def row_digests(relation, columns)
        meaningful = columns - %w[updated_at created_at]
        relation.order(:id).pluck(*meaningful).map do |values|
          row = Array(values)
          [row.first, Digest::SHA256.hexdigest(row.map(&:to_s).join("\x1f")).first(16)]
        end
      end

      # `variant_category` is declared on Variant, not on BaseVariant (Sku and
      # other subtypes don't carry it), so join through the categories table by
      # column rather than by association name — that covers every subtype the
      # editor can delete.
      def alive_variant_stamps(product)
        stamped(
          BaseVariant.alive.where(variant_category_id: product.variant_categories.alive.select(:id))
        )
      end

      def digest(fingerprint)
        OpenSSL::HMAC.hexdigest(
          "SHA256",
          Rails.application.secret_key_base,
          fingerprint.to_json
        ).first(32)
      end
  end
end
