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
# the alive ids of all five collections, plus the few product attributes that
# change what a save is allowed to delete (DELETION_RELEVANT_ATTRIBUTES).
#
# Deliberately NOT a timestamp. A digest changes only when something the
# contract cares about changes, so an unrelated write — a price edit, a tag —
# does not invalidate a seller's in-flight deletion. That matters because an
# earlier attempt at this DID reject saves whenever anything on the product had
# changed, which refused so much legitimate work that its seller-visible
# rejection had to be turned off again (#6245). A token that cries stale too
# often ends up switched off and protecting nothing.
class Product::EditorRevision
  # Bumping this invalidates every outstanding token. Do that when the set of
  # things the digest covers changes, so an old token cannot be read as current
  # against a new definition.
  #
  # v2: each collection now contributes updated_at as well as id, so edits to
  # existing children move the token and not just additions and removals.
  # v3: the product's own updated_at is no longer part of the digest. Every
  # write to a product bumps updated_at, so including it meant a co-editor
  # renaming or retagging the product invalidated another tab's outstanding
  # deletion — the too-many-false-conflicts behaviour described above, which
  # this class exists to avoid. Replaced by the named attributes in
  # DELETION_RELEVANT_ATTRIBUTES.
  # v4: is_physical and skus_enabled joined that list, and SKU rows are now
  # witnessed (they hang off the product rather than a version category, so the
  # variant stamps did not see them).
  VERSION = "v4"

  # Product attributes that change WHAT A SAVE MAY DELETE, and therefore have
  # to be witnessed by the token. This is deliberately a short allowlist rather
  # than `updated_at`: everything absent from it (price, name, tags,
  # description, visibility, …) can be edited by a co-editor without
  # invalidating a stale tab's in-flight deletion, because none of it changes
  # which rows that deletion would remove.
  #
  # - has_same_rich_content_for_all_variants: when this is on, the product has
  #   one shared set of content pages instead of a separate set per version, and
  #   the editor is not shown the per-version pages at all. So an editor session
  #   that loaded while it was off built its payload from a different set of
  #   pages than one that loads while it is on, and a deletion computed against
  #   the first set means something different against the second. A real product
  #   lost its content this way (three times in nine days, July 2026): the
  #   stored state left the editor with no version content to submit, so an
  #   ordinary save looked like "the seller deleted every version page".
  #   Product::RichContentDeletionGuard reads the persisted value for the same
  #   reason.
  # - is_tiered_membership: memberships and ordinary products delete versions by
  #   different routes, and only the membership route also sweeps the version's
  #   recurring prices. A token issued while the product was one kind describes
  #   a deletion that would do something different now it is the other.
  # - is_physical: physical products always resolve to the product-level content
  #   pages, ignoring per-version pages entirely (Link#has_product_level_rich_content?
  #   short-circuits on it, and the editor's own presenter does the same). So
  #   flipping it changes which set of pages the editor loads and therefore which
  #   pages a deletion computed from that load would remove.
  # - skus_enabled: when on, the save additionally runs Product::SkusUpdaterService,
  #   which soft-deletes the SKU rows missing from the payload — and deletes every
  #   non-default SKU outright when no version category is left. A token issued
  #   while it was off describes a save that could not touch SKUs at all.
  DELETION_RELEVANT_ATTRIBUTES = %w[
    has_same_rich_content_for_all_variants
    is_tiered_membership
    is_physical
    skus_enabled
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
      # tag): those still must not invalidate an in-flight deletion, because
      # rejecting saves on unrelated edits is what got the earlier attempt
      # switched off (#6245). That is why the product contributes only
      # DELETION_RELEVANT_ATTRIBUTES and not its own updated_at.
      def fingerprint(product)
        {
          version: VERSION,
          product: product.id,
          product_state: product_state(product),
          rich_content: stamped(product.alive_rich_contents),
          variants: alive_variant_stamps(product),
          skus: sku_stamps(product),
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
      # These are not database columns: Link packs many booleans into a single
      # `flags` integer via the flag_shih_tzu gem, which defines a reader per
      # bit. So they are absent from `column_names` and the existence check has
      # to ask `respond_to?` instead — checking column_names here would reject
      # every one of them.
      #
      # Raises if an attribute stops existing rather than skipping it. Silently
      # dropping one would leave the token blind to a change that alters what a
      # deletion removes, which is exactly what this class exists to prevent, so
      # a loud failure is the safer default.
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
      #
      # Skus are the exception: they hang off the product directly and leave
      # variant_category_id null, so the scope below cannot see them even though
      # Product::SkusUpdaterService soft-deletes them during a save. They are
      # collected separately in sku_stamps.
      def alive_variant_stamps(product)
        stamped(
          BaseVariant.alive.where(variant_category_id: product.variant_categories.alive.select(:id))
        )
      end

      # Skus belong to the product rather than to a version category, so they sit
      # outside alive_variant_stamps' scope. Without them the token cannot
      # witness a SKU being added or removed by another tab, and a stale
      # deletion would look fresh while SkusUpdaterService sweeps rows the
      # submitting session never saw.
      def sku_stamps(product)
        stamped(Sku.alive.where(link_id: product.id))
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
