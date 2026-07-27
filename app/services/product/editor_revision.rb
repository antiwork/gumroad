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
# the alive ids of all five collections, plus the product's own updated_at.
# Deliberately NOT a timestamp — a digest changes only when something the
# contract cares about changes, so an unrelated write (a price edit, a tag) does
# not invalidate a seller's in-flight deletion and produce the false conflicts
# that killed #6245.
class Product::EditorRevision
  # Bumping this invalidates every outstanding token. Do that when the set of
  # things the digest covers changes, so an old token cannot be read as current
  # against a new definition.
  VERSION = "v1"

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
      def fingerprint(product)
        {
          version: VERSION,
          product: product.id,
          updated_at: product.updated_at&.to_fs(:usec),
          rich_content: product.alive_rich_contents.order(:id).pluck(:id),
          variants: alive_variant_ids(product),
          variant_categories: product.variant_categories.alive.order(:id).pluck(:id),
          files: product.product_files.alive.order(:id).pluck(:id),
          public_files: product.alive_public_files.order(:id).pluck(:id),
          integrations: product.active_integrations.order(:id).pluck(:id),
        }
      end

      # `variant_category` is declared on Variant, not on BaseVariant (Sku and
      # other subtypes don't carry it), so join through the categories table by
      # column rather than by association name — that covers every subtype the
      # editor can delete.
      def alive_variant_ids(product)
        BaseVariant.alive
                   .where(variant_category_id: product.variant_categories.alive.select(:id))
                   .order(:id)
                   .pluck(:id)
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
