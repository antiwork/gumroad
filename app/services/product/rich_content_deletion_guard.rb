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
#   for all versions"), or
# - the seller confirmed the deletion in the editor (delete-page modal, copy
#   content from another version, discard other versions' content), which the
#   client reports via confirmed_removed_rich_content_ids.
#
# Pages with a blank description are deletable without confirmation — they carry
# no content, and the editor legitimately drops them in several flows.
class Product::RichContentDeletionGuard
  MESSAGE = "This save would remove content pages that weren't explicitly deleted. Your product may have been updated in another tab — please refresh the page and try again."

  def self.ensure_intent!(product:, rich_contents_to_delete:, payload_page_ids:, confirmed_removed_ids:)
    unconfirmed = rich_contents_to_delete.select do |rich_content|
      rich_content.description.present? &&
        !payload_page_ids.include?(rich_content.external_id) &&
        !confirmed_removed_ids.include?(rich_content.external_id)
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
end
