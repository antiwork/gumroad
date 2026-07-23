# frozen_string_literal: true

# Blocks a product-editor save from deleting content pages the seller didn't
# explicitly delete. The editor always submits the FULL list of pages, so a page
# that exists in the database but is missing from the payload normally means the
# seller deleted it in the UI. However, a stale browser tab (or a race between
# two editor sessions) can submit an outdated page list, in which case the save
# silently soft-deletes every page the payload doesn't know about — wiping the
# seller's product content in a single ordinary save.
#
# A page deletion is considered intentional when either:
# - the page's id appears elsewhere in the same payload (the page moved between
#   the product level and a variant, e.g. when toggling "use the same content
#   for all versions"),
# - the page's exact content appears in the payload under an id the server
#   doesn't know. The editor keeps client-generated ids for pages created in
#   the current session (it never learns the server's ids), so the second save
#   of such a page arrives with an unknown id and the server re-creates it — a
#   rewrite, not a deletion. A stale-tab wipe doesn't resubmit the content, so
#   it stays blocked. Matching is count-aware: N identical unknown-id payload
#   pages can only account for N deleted pages, so a duplicate-content page
#   omitted by a stale payload can't hide behind its surviving twin. Or,
# - the seller confirmed the deletion in the editor (delete-page modal, copy
#   content from another version, discard other versions' content), which the
#   client reports via confirmed_removed_rich_content_ids.
#
# Pages without visible editor content (a blank description, or only empty
# structural nodes like the single bare paragraph the editor creates as a
# placeholder) are deletable without confirmation — they carry nothing a buyer
# could see, and the editor legitimately drops them in several flows.
class Product::RichContentDeletionGuard
  MESSAGE = "This save would remove content pages that weren't explicitly deleted. Your product may have been updated in another tab — please refresh the page and try again."

  # rewrite_budget: the shared allowance built by .build_rewrite_budget for the
  # whole save request. The guard runs several times per save (once for the
  # product-level pages, once per variant), so the SAME hash must be passed to
  # every call — building a fresh budget per call would let one resubmitted
  # page account for one omitted stored page in each scope instead of one
  # total. Entries are consumed (mutated) as they authorize rewrites.
  def self.ensure_intent!(product:, rich_contents_to_delete:, payload_page_ids:, confirmed_removed_ids:, rewrite_budget: {})
    unconfirmed = rich_contents_to_delete.select do |rich_content|
      next false unless rich_content.has_editor_content?
      next false if payload_page_ids.include?(rich_content.external_id)
      next false if confirmed_removed_ids.include?(rich_content.external_id)

      normalized = normalize_description(rich_content.description.as_json)
      if rewrite_budget[normalized].to_i > 0
        rewrite_budget[normalized] -= 1
        next false
      end
      true
    end
    return if unconfirmed.empty?

    ErrorNotifier.notify(
      "Blocked product save that would delete content pages without confirmation",
      product_id: product.id,
      rich_content_ids: unconfirmed.map(&:id)
    )
    product.errors.add(:base, MESSAGE)
    raise Link::LinkInvalid, MESSAGE
  end

  # Builds the request-wide rewrite allowance from the unknown-id payload page
  # descriptions: each unknown-id payload page can account for at most one
  # deleted stored page (the one it rewrites), so track a consumable count per
  # normalized description. Build this ONCE per save request and pass the same
  # hash to every ensure_intent! call so the allowance is shared across the
  # product-level and per-variant guard invocations.
  def self.build_rewrite_budget(payload_page_descriptions)
    Array.wrap(payload_page_descriptions).map { |description| normalize_description(description) }.tally
  end

  # File ids inside fileEmbed nodes are rewritten between client and server
  # representations of the same file (the client may hold the hex id while the
  # stored page holds the base64 external id), so they can't be compared
  # directly. The embed's uid — a stable client-generated identity — stays the
  # same, so content comparison drops the id and keeps everything else.
  def self.normalize_description(description)
    case description
    when Array then description.map { |node| normalize_description(node) }
    when Hash then description.except("id", :id).transform_values { |value| normalize_description(value) }
    else description
    end
  end
end
