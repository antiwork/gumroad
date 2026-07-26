# frozen_string_literal: true

# Decides whether a product-editor save payload actually *describes* each of the
# two collections it can carry — the product's content pages and its versions —
# before the save acts on them.
#
# The problem this exists to solve: an empty collection and an uninterpretable
# one look identical by the time the save runs. Strong parameters silently DROPS
# a value whose shape doesn't match the policy (a scalar where a list of hashes
# is declared), so a payload that sent its versions as, say, a string arrives at
# the save with no `variants` key at all — exactly like a payload from a product
# that genuinely has no versions. The save then reads that absence as "the
# seller removed everything", and the content deletion guards
# (Product::RichContentDeletionGuard,
# Product::VariantCategoryUpdaterService.ensure_deletion_intent!) stop the save
# and tell the seller their editor may be out of date and to refresh the page.
#
# Refreshing does not fix a malformed request. The seller reloads, saves again,
# gets the same message, and there is nothing they can do about it — the bug is
# in the payload their browser sent, not in anything they can see or change.
#
# So rather than describing the broken payload to the seller, the save treats an
# uninterpretable collection as **not submitted**: the rest of the save applies
# normally and that collection is left exactly as it is on the server. A save
# that sends unreadable versions no longer touches the versions, and no longer
# needs the seller's permission to not touch them. Nothing is deleted, nothing
# is silently overwritten, and the seller's other edits still land.
#
# Every rejection here is a client bug — no sequence of actions in the editor can
# make a seller submit a scalar where a list belongs — so each one is reported to
# Sentry with a reason code. A spike is the signal that an editor build is
# emitting bad payloads, which is the diagnosis that the "please refresh"
# rejections were hiding.
#
# Deliberately NOT judged here: whether the ids in the payload name records of
# this product. That sounds like the same class of check but it is not answerable
# yet. A page the seller just created is submitted under a client-generated id
# the server has never seen — that is the normal, supported flow (the save
# response returns `rich_content_id_mappings` so the editor can adopt the
# canonical id afterwards). An unrecognised id is therefore indistinguishable
# from a genuinely foreign one until client ids are namespaced per owner and
# minted uniquely per copy, which is the identity work in gumroad-private#1360.
# Treating an unknown id as "uninterpretable" here would make the first save of
# every new page skip the pages collection — silently dropping the seller's new
# content, which is worse than the message this class replaces.
#
# Scope note: this reads the two collections the dashboard editor sends as JSON
# arrays. Rails' strong parameters also accepts an integer-keyed hash
# (`variants[0][name]=…`) where an array is declared, which this would call
# uninterpretable — the editor always sends JSON, so that only matters if some
# scripted client ever posts this endpoint form-encoded.
class Product::SavePayloadIntegrity
  # A collection is uninterpretable if it isn't a list, or if it is a list whose
  # entries aren't records. Anything else — including an empty list, and
  # including entries whose ids the server doesn't recognise — is a payload the
  # save can act on.
  Result = Struct.new(:skipped_pages_reason, :skipped_variants_reason, keyword_init: true) do
    # Pages are skipped when the pages themselves were unreadable, and ALSO
    # when the versions were: the editor decides which files to submit from the
    # content it is submitting (a file is kept if some page embeds it), so a
    # payload that couldn't describe its versions also can't be trusted about
    # which files and pages that content needs. Applying the readable half of
    # the content against a file list derived from the unreadable half is how
    # you delete a file a surviving page still embeds.
    def skip_pages?
      skipped_pages_reason.present? || skipped_variants_reason.present?
    end

    def skip_variants?
      skipped_variants_reason.present?
    end

    # Whether any of the product's content — pages, versions, or the files they
    # embed — has to be left as the server already has it.
    def skip_content?
      skip_pages? || skip_variants?
    end

    def any?
      skip_content?
    end
  end

  # raw_params: the unfiltered request params. This has to read the raw params
  # rather than the permitted ones, because permitting is what erases the
  # evidence: a malformed collection is already gone from the permitted params,
  # indistinguishable from one the client never sent.
  def self.check(product:, raw_params:)
    new(product:, raw_params:).check
  end

  def initialize(product:, raw_params:)
    @product = product
    @raw_params = raw_params
  end

  def check
    result = Result.new(
      skipped_pages_reason: uninterpretable_reason(raw_params[:rich_content], collection: "pages", pages: true),
      skipped_variants_reason: uninterpretable_reason(raw_params[:variants], collection: "variants"),
    )

    # A version whose own pages are unreadable makes the whole versions
    # collection unusable: saving those versions would apply them with no
    # content, which is the deletion this is preventing.
    if !result.skip_variants? && raw_params[:variants].is_a?(Array)
      raw_params[:variants].each do |variant|
        reason = uninterpretable_reason(variant[:rich_content], collection: "version_pages", pages: true)
        next if reason.blank?

        result.skipped_variants_reason = reason
        break
      end
    end

    report(result)
    result
  end

  private
    attr_reader :product, :raw_params

    # pages: whether this collection holds content PAGES, whose bodies get the
    # extra check below. Versions are not pages — a version's `description` is
    # an ordinary string field, so applying the page-body rule to them would
    # reject every version that has a description.
    def uninterpretable_reason(value, collection:, pages: false)
      return nil if value.nil?
      return "#{collection}_not_a_list" unless value.is_a?(Array)
      return "#{collection}_entry_not_a_record" unless value.all? { record?(_1) }
      return "#{collection}_body_not_a_record" if pages && !value.all? { readable_page_body?(_1) }

      nil
    end

    # A page's body has to be readable too, not just the page entry. This is
    # where the most damaging shape hides: an entry that IS a record but whose
    # `description` isn't one passes an entry-level check, and permitting then
    # DROPS the unreadable body while keeping the entry. The save reads that as
    # "this page now has no body" and replaces the seller's content with an
    # empty document — a committed content wipe, from a payload the seller
    # can't see or fix. The nodes matter for the same reason: a body whose
    # `content` is a scalar crashes the save mid-transaction, and one whose
    # nodes are bare strings gets stored as the page's content (every
    # downstream filter reads `node["type"]`, which is nil on a String, so
    # nothing rejects them).
    #
    # Absent or blank is fine — a page can legitimately be submitted with no
    # body (the rest of the save already treats a blank description as "no
    # body"), and an empty node list is a page the seller emptied on purpose.
    def readable_page_body?(page)
      body = page[:description]
      return true if body.blank?
      return false unless record?(body)

      nodes = body[:content]
      return true if nodes.nil?

      nodes.is_a?(Array) && nodes.all? { record?(_1) }
    end

    def record?(value)
      value.is_a?(ActionController::Parameters) || value.is_a?(Hash)
    end

    def report(result)
      return unless result.any?

      ErrorNotifier.notify(
        "Skipped an uninterpretable collection in a product save payload",
        product_id: product.id,
        skipped_pages_reason: result.skipped_pages_reason,
        skipped_variants_reason: result.skipped_variants_reason,
      )
    end
end
