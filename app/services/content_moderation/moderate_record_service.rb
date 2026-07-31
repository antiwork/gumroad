# frozen_string_literal: true

class ContentModeration::ModerateRecordService
  AUTHOR_NAME = "ContentModeration"
  ADMIN_COMMENT_DEDUP_WINDOW = 5.minutes

  # How long we're willing to spend looking files up in storage while deciding
  # whether a listing delivers anything (see `has_deliverable_file?`). This is a
  # time budget rather than a file count so that no attached file is excluded
  # from the check by its position in the list.
  STORAGE_CHECK_TIME_BUDGET_SECONDS = 2.0

  # One storage-check budget, shared by a product and every variant it carries,
  # so a single save spends one budget however many file lists it contains.
  #
  # It also collects which files were left unchecked once the time ran out. The
  # collection is deliberately kept here rather than logged by each list, because
  # running out of time is one event for the whole save: a membership with ten
  # tiers would otherwise emit ten separate warnings for it, and none of them
  # would say how many files went unchecked in total. The caller logs the total
  # once, after the whole check has finished.
  #
  # Files are tracked by id rather than counted, because the same file can turn
  # up in more than one list: a file attached to a tier also belongs to the
  # product, since `ProductFile#link_id` points at the product either way, so the
  # product's own list and the tier's list both walk it. Counting would report a
  # bigger total than the number of files the seller actually attached, and would
  # report a file as unchecked even when an earlier list had already looked it up.
  class StorageCheckBudget
    def initialize(seconds:)
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      @checked_file_ids = Set.new
      @skipped_file_ids = Set.new
    end

    def spent?
      Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
    end

    def record_checked_file(file)
      @checked_file_ids << file.id
    end

    def record_skipped_files(files)
      @skipped_file_ids.merge(files.map(&:id))
    end

    # Files nobody ever got to look up. A file skipped by one list but already
    # looked up by an earlier one was checked, so it doesn't count.
    def unchecked_file_count
      (@skipped_file_ids - @checked_file_ids).size
    end
  end
  private_constant :StorageCheckBudget

  CheckResult = Struct.new(:passed, :reasons, keyword_init: true)

  CATEGORY_LABELS = {
    "harassment" => "harassment",
    "harassment/threatening" => "threatening harassment",
    "hate" => "hateful content",
    "hate/threatening" => "threatening hateful content",
    "illicit" => "illicit content",
    "illicit/violent" => "instructions for violence",
    "self-harm" => "self-harm content",
    "self-harm/intent" => "self-harm content",
    "self-harm/instructions" => "self-harm content",
    "sexual" => "sexual content",
    "sexual/minors" => "sexual content involving minors",
    "violence" => "violent content",
    "violence/graphic" => "graphic violence",
  }.freeze

  # PromptStrategy prefixes its reasons with the preset name (e.g.
  # "spam: <model reasoning>"). Map those presets to a phrase the seller can
  # act on, since the free-text reasoning itself never matches a category.
  PROMPT_PRESET_LABELS = {
    "spam" => "content that reads as promotional spam",
    "adult_content" => "adult content",
    "off_platform_fulfillment" => "off-platform fulfillment",
  }.freeze

  # `humanize_reasons` phrases most violations as something the content
  # "contains". Off-platform fulfillment is the opposite shape — the problem is
  # what the listing is MISSING — so it gets its own sentence instead of being
  # forced into that template.
  OFF_PLATFORM_FULFILLMENT_MESSAGE =
    "Buyers need to receive what they paid for on Gumroad. This %<noun>s has no content attached and " \
    "directs buyers to message you on another platform to get it, which we don’t allow. Add the files, " \
    "videos, or written content buyers should get when they buy, then publish again."

  # Turn raw moderation reasons (e.g. "OpenAI moderation flagged: violence
  # (score: 0.86, threshold: 0.9)" or "spam: repeated unrelated slogans") into
  # a friendly, de-duplicated phrase the seller can act on — without leaking
  # scores, thresholds, or the provider. Generic fallback for blocklist
  # reasons that aren't a known category.
  def self.humanize_reasons(reasons)
    labels = Array(reasons).map do |r|
      preset = r.to_s.split(":").first.to_s.strip.downcase
      next PROMPT_PRESET_LABELS[preset] if PROMPT_PRESET_LABELS.key?(preset)

      key = r.to_s.split(" (").first.to_s.split(": ").last.to_s.strip.downcase
      CATEGORY_LABELS[key]
    end.compact.uniq
    labels.empty? ? "something that may violate our content guidelines" : labels.to_sentence
  end

  # `title` names the specific record in the error (e.g. which email of a
  # 17-email workflow was flagged) so sellers don't have to guess what to fix.
  def self.seller_message(reasons, noun, title: nil)
    rs = Array(reasons)
    transient = ContentModeration::Strategies::ClassifierStrategy::UNAVAILABLE_REASON
    if rs.any? && rs.all? { |r| r.to_s.include?(transient) }
      "We couldn’t review this #{noun} just now (a temporary issue on our end). Please try again in a few minutes."
    elsif rs.any? { |r| off_platform_fulfillment_reason?(r) }
      message = format(OFF_PLATFORM_FULFILLMENT_MESSAGE, noun: noun)
      # A run can flag off-platform fulfillment alongside another violation
      # (e.g. adult content). Naming only the missing-content problem would
      # send the seller back to add files and then block them again for the
      # reason we withheld, so both are reported at once.
      others = rs.reject { |r| off_platform_fulfillment_reason?(r) }
      others.any? ? "#{message} It also looks like this #{noun} contains #{humanize_reasons(others)}." : message
    else
      subject = title.present? ? "The #{noun} \"#{title}\"" : "This #{noun}"
      "#{subject} can’t be saved because it looks like it contains #{humanize_reasons(reasons)}. Please update the content to follow our content guidelines."
    end
  end

  def self.check(record, entity_type)
    new(record, entity_type).check
  end

  def self.off_platform_fulfillment_reason?(reason)
    reason.to_s.start_with?("off_platform_fulfillment:")
  end
  private_class_method :off_platform_fulfillment_reason?

  def initialize(record, entity_type)
    @record = record
    @entity_type = entity_type
  end

  def check
    return CheckResult.new(passed: true, reasons: []) unless moderation_enabled?
    return CheckResult.new(passed: true, reasons: []) if user&.verified?
    return CheckResult.new(passed: true, reasons: []) if record_moderation_disabled?

    content = extract_content
    return CheckResult.new(passed: true, reasons: []) if content.text.blank? && content.image_urls.empty?

    blocklist_result = ContentModeration::Strategies::BlocklistStrategy
                         .new(text: content.text, image_urls: content.image_urls)
                         .perform

    if blocklist_result.status == "flagged"
      leave_admin_comment(blocklist_result.reasoning)
      return CheckResult.new(passed: false, reasons: blocklist_result.reasoning)
    end

    ai_results = run_ai_strategies(content)
    flagged = ai_results.select { |r| r.status == "flagged" }

    # Judgment-preset flags (spam, off-platform fulfillment) that didn't
    # reproduce when PromptStrategy resampled them. They don't block the
    # publish, but we still leave a note so the flag rate and false-positive
    # rate can be measured against blocked publishes.
    audit_reasons = ai_results.flat_map { |r| r.respond_to?(:audit_reasoning) ? Array(r.audit_reasoning) : [] }

    reasons = flagged.flat_map(&:reasoning)

    # A spam flag on a product that actually delivers something is downgraded
    # to a note instead of blocking the publish (see
    # `spam_flag_should_not_block?`).
    #
    # Asked only when there is a spam flag to downgrade. Answering it means
    # walking the product's files and, for files their own row can't answer for,
    # spending up to a two-second budget on storage lookups — work that changes
    # nothing when nothing was flagged, and whose "we ran out of time" warning
    # would otherwise be written during saves that go on to succeed.
    if reasons.any? { |r| spam_reason?(r) } && spam_flag_should_not_block?
      downgraded, reasons = reasons.partition { |r| spam_reason?(r) }
      audit_reasons += downgraded.map { |r| "#{r} (#{spam_downgrade_note_reason})" }
    end

    leave_admin_comment(audit_reasons, blocked: false) if audit_reasons.any?

    if reasons.any?
      leave_admin_comment(reasons)
      CheckResult.new(passed: false, reasons: reasons)
    else
      CheckResult.new(passed: true, reasons: [])
    end
  end

  private
    attr_reader :record, :entity_type

    def moderation_enabled?
      # The :content_moderation flag is fully enabled in production and is kept ONLY as an
      # operational kill switch (disable it to turn off automated moderation globally, e.g. if the
      # classifier misbehaves). It was deliberately excluded from the rollout-flag cleanup in
      # gumroad-private#1208 and should be removed once we're confident we never need to disable
      # moderation globally. Do not treat it as a rollout gate.
      Feature.active?(:content_moderation)
    end

    def record_moderation_disabled?
      case entity_type
      when :product then record.content_moderation_disabled?
      # A page inherits the escape hatch from the product it takes over, so
      # turning moderation off for a product covers its landing page too --
      # otherwise the exemption would hold for the product and then block the
      # page that replaces it.
      when :page then record.pageable.is_a?(Link) && record.pageable.content_moderation_disabled?
      else false
      end
    end

    def spam_reason?(reason)
      reason.to_s.start_with?("spam:")
    end

    # Whether a spam flag should be recorded as a note instead of blocking the
    # publish.
    #
    # The spam preset is a judgment call about intent, and in practice it fires
    # on the writing STYLE of the info-product genre (an all-caps headline
    # repeated in the description, benefit bullets with little prose between
    # them, earnings framing) rather than on anything that makes a listing
    # actually spam. A seller with a real ebook attached hit this ten times in
    # fifteen minutes and had no way to tell what to change
    # (gumroad-private#1358).
    #
    # The signal that separates the two cases is whether the listing delivers
    # anything: keyword-stuffed link farms and fake listings have nothing
    # attached, while a product with files, readable content, or a
    # Gumroad-provisioned community invite is selling something real, however
    # loudly it is written. So for a product that has a deliverable we keep the
    # flag as a reviewable note and let the publish through; for an empty
    # listing the flag still blocks, as do all the other presets and the
    # blocklist, which key on concrete content rather than tone.
    #
    # Posts are unaffected: they have no deliverable of their own, so a spam
    # flag on a post keeps blocking as before.
    #
    # A page has no deliverable of its own, so the product test above can't be
    # applied to it. What stands in for it is whether the page belongs to a real
    # storefront: a seller with live products or completed sales has something
    # the page is plausibly selling, and blocking on tone there would mean an
    # agent that wrote a perfectly ordinary sales page cannot save it and cannot
    # be told what to change. A seller with neither is the shape this change
    # exists to stop — an agent or the CLI standing up a link farm on a
    # gumroad.com subdomain — and the spam preset (whose flag conditions name
    # link farms and keyword stuffing explicitly) is the only preset that reads
    # it, so for them a corroborated spam flag keeps blocking.
    def spam_flag_should_not_block?
      return seller_has_storefront? if entity_type == :page

      entity_type == :product && product_has_substantive_deliverable?
    end

    # Why an admin is reading a downgraded spam flag rather than a block. A page
    # is not a listing and has nothing attached, so it can't borrow the product
    # wording.
    def spam_downgrade_note_reason
      entity_type == :page ? "not blocked: seller has a live storefront" : "not blocked: listing has content attached"
    end

    # Whether the page's owner has anything on Gumroad besides the page. Kept to
    # two indexed existence checks: this is asked inside a save, and only when
    # there is a spam flag to downgrade.
    def seller_has_storefront?
      return false if user.blank?

      user.links.alive.exists? || user.sales.successful.exists?
    end

    # The stricter half of "does this listing deliver anything", used only to
    # decide whether a corroborated spam flag stops being a block.
    #
    # `product_has_deliverable?` is deliberately generous because it gates a
    # QUESTION we ask a model (see `check_off_platform_fulfillment?`): being
    # generous there only means we don't ask, and the other presets still run.
    # Here the same generosity would let a listing publish, so states a spammer
    # can produce for free are not enough:
    #
    #   - a page with a title and nothing in it (the title renders in the
    #     buyer's page list, but there is nothing to read),
    #   - a bundle with no component products in it,
    #   - a "coffee"/tip listing, which has no deliverable by design,
    #   - an attached file whose upload never finished, so there is nothing in
    #     storage to hand the buyer (see `has_deliverable_file?`),
    #   - an integration Gumroad does not fulfil on purchase (only a Circle or
    #     Discord invite is itself the thing the buyer receives; a Zoom or
    #     Google Calendar connection is scheduling plumbing attached to a call).
    #
    # Everything that does establish a real deliverable still downgrades the
    # flag: uploaded files at the product or variant level, a content page with
    # an actual body, a physical product (it ships), a bundle that contains
    # products, a call or commission (work the seller performs), or a
    # Gumroad-provisioned community invite.
    def product_has_substantive_deliverable?
      return true if record.is_physical?
      return true if record.is_bundle? && record.bundle_products.alive.any?
      return true if record.native_type.in?([Link::NATIVE_TYPE_CALL, Link::NATIVE_TYPE_COMMISSION])
      return true if gumroad_fulfilled_community_integration?

      # One budget for the whole product, not one per file list. A product
      # carries its own files and a separate list per variant, so giving each
      # list its own budget would multiply the worst case by the number of
      # variants a single save can contain.
      budget = StorageCheckBudget.new(seconds: STORAGE_CHECK_TIME_BUDGET_SECONDS)

      found_file = has_deliverable_file?(record, budget:) ||
        record.alive_variants.any? { |variant| has_deliverable_file?(variant, budget:) }

      # Readable page content establishes a deliverable on its own, so a product
      # that has some passes whether or not we got through its files.
      has_deliverable = found_file || has_readable_body_content?(record)

      # Say so once for the whole save when a spent budget left files unchecked
      # and the product still came out with no deliverable, so a rejection that
      # only means "we ran out of time" is explicable from the logs.
      #
      # Two things about where this sits are deliberate. It is outside the
      # per-list check, so a membership with many tiers produces one line
      # carrying the total rather than one line per tier. And it waits for the
      # whole answer rather than just the file half of it, so a product that ran
      # out of budget on its files but passed on its page content doesn't carry a
      # failure-shaped warning about files nobody needed to look at.
      if !has_deliverable && budget.unchecked_file_count.positive?
        Rails.logger.warn(
          "ContentModeration: storage check budget spent with " \
          "#{budget.unchecked_file_count} unverifiable file(s) left unchecked on " \
          "#{record.class.name} ##{record.id}"
        )
      end

      has_deliverable
    end

    # An attached file only counts when there is really something in storage
    # behind it.
    #
    # An alive `ProductFile` row is not by itself proof that the buyer receives a
    # file: a product save that races an unfinished multipart upload leaves a row
    # pointing at a key that was never written, and nothing deletes that row
    # afterwards (see `ProductFile#stored_file_present?`). Counting it here
    # would hand back the bypass the rest of this method closes — attach nothing,
    # abandon an upload, publish anyway. The same goes for a long list of such
    # rows: the save API takes each file's storage URL from the client, so a
    # caller can submit as many never-uploaded rows as it likes, and "there are
    # a lot of them" is not evidence that any one is real.
    #
    # Most files answer from the row alone (an analyzed file, an external link, a
    # purged object), so those are settled first and for free. Only files the row
    # cannot answer for cost a request to storage, and those are bounded by a time
    # budget rather than a file count.
    #
    # A count-based cap had to choose WHICH files to spend it on, and every choice
    # left a real deliverable unreachable. A file a row cannot answer for has
    # never been analyzed successfully, and a genuinely stored file lands in that
    # state at either end of creation order: it was uploaded moments ago and
    # AnalyzeFileWorker hasn't run yet (the newest such row), or its analysis will
    # never succeed even though the object is really there — the worker exhausted
    # its retries, or it's a video whose metadata can't be read, which clears the
    # flag deliberately (see WithFileProperties#video_analysis_failed) and which
    # nothing ever revisits, so it ages into being the oldest such row. Checking
    # the newest few plus the oldest few covers both, but then a stored file
    # sitting BETWEEN two runs of abandoned uploads falls in the gap and the
    # seller is told their listing delivers nothing.
    #
    # There is no ordering that fixes this, because the save API takes each file's
    # storage URL from the client: whatever slice we pick, a caller can submit
    # enough dead rows to push a real file out of it, and a legitimate seller can
    # land there by accident. So instead every unverifiable file is eligible, and
    # what's capped is the time spent — we stop asking once the budget is gone.
    # Ordering newest-first still matters, since the freshly-uploaded file is the
    # single likeliest deliverable and usually answers on the first request.
    #
    # A listing carrying many dead rows therefore costs a bounded amount of time
    # instead of a bounded number of files, and no attached file is excluded from
    # the check by its position in the list.
    #
    # An exhausted budget still fails the check, which is deliberate: running out
    # of time means we could not prove there is a deliverable, and passing on
    # "we don't know" would hand back exactly the bypass this method exists to
    # close, since the caller decides how many rows the check has to get through.
    # What the budget changes is that exhaustion now takes genuinely slow storage
    # responses rather than being guaranteed by row count alone, and when it does
    # happen we say so in the log instead of failing silently.
    #
    # This can only decide how cheaply an honest seller is confirmed; it can never
    # let an empty listing through, because passing still requires an object to
    # actually be in storage.
    def has_deliverable_file?(owner, budget:)
      unverifiable_from_row = []

      owner.alive_product_files.each do |file|
        case file.stored_file_presence_known_from_row
        when true then return true
        when nil then unverifiable_from_row << file
        end
      end

      # Newest first: a freshly-uploaded file is the likeliest deliverable, so it
      # usually answers on the first request.
      newest_first = unverifiable_from_row.sort_by { -_1.id }

      newest_first.each_with_index do |file, checked|
        if budget.spent?
          # Everything from here on, including the file whose turn it was, went
          # unrequested by this list. Handed over as records so the budget can
          # tell a file no list ever reached from one an earlier list looked up.
          budget.record_skipped_files(newest_first.drop(checked))
          break
        end

        budget.record_checked_file(file)
        return true if file.stored_file_present?
      end

      false
    end

    # Rich content with something in the body, ignoring pages that only have a
    # title. See `product_has_substantive_deliverable?` for why the title alone
    # doesn't count here even though it counts for the off-platform preset.
    #
    # Blocks that don't themselves give the buyer anything are also ignored (see
    # RichContent::NODE_TYPES_WITHOUT_OWN_CONTENT): a `posts` block on a listing
    # with no published posts and a `fileEmbed` pointing at a missing file both
    # render nothing at all, and a recommendation, an upsell for another product
    # or a form field asks something of the buyer rather than delivering to them.
    # Each is one click to insert, so dropping one into an otherwise empty page
    # is not a deliverable. A file that really is attached still downgrades the
    # flag — the `alive_product_files` checks in
    # `product_has_substantive_deliverable?` cover that case directly, without
    # needing the embed node to vouch for it.
    def has_readable_body_content?(product)
      has_own_body_content = ->(rich_content) do
        rich_content.has_body_content?(excluding_node_types: RichContent::NODE_TYPES_WITHOUT_OWN_CONTENT)
      end

      product.alive_rich_contents.any?(&has_own_body_content) ||
        product.alive_variants.any? { |variant| variant.alive_rich_contents.any?(&has_own_body_content) }
    end

    # An integration whose invite IS what the buyer receives, and which Gumroad
    # itself provisions and records on purchase.
    def gumroad_fulfilled_community_integration?
      names = [Integration::CIRCLE, Integration::DISCORD]

      record.active_integrations.where(type: names.map { Integration.type_for(_1) }).exists? ||
        record.alive_variants.any? do |variant|
          variant.active_integrations.where(type: names.map { Integration.type_for(_1) }).exists?
        end
    end

    # Whether the buyer receives something for their money. This is the
    # inverse of the emptiness test `check_off_platform_fulfillment?` performs,
    # including the record types whose deliverable is not content at all (a
    # physical product ships, a bundle delivers its component products, a
    # call/commission is work the seller performs).
    def product_has_deliverable?
      return true if record.is_physical? || record.is_bundle?
      return true if Link::SERVICE_TYPES.include?(record.native_type)
      return true if gumroad_managed_integration?

      record.alive_product_files.any? ||
        record.alive_variants.any? { |variant| variant.alive_product_files.any? } ||
        has_reader_visible_content?(record)
    end

    def extract_content
      extractor = ContentModeration::ContentExtractor.new
      case entity_type
      when :product then extractor.extract_from_product(record)
      when :post then extractor.extract_from_post(record)
      when :page then extractor.extract_from_page(record)
      end
    end

    def run_ai_strategies(content)
      strategies = [
        ContentModeration::Strategies::ClassifierStrategy.new(text: content.text, image_urls: content.image_urls),
        # `corroborate_judgment_flags` makes a spam or off-platform-fulfillment
        # flag block only when it reproduces on resampling; a lone flag is
        # returned as audit_reasoning and recorded as a non-blocking note
        # instead (see `check` above).
        ContentModeration::Strategies::PromptStrategy.new(
          text: content.text,
          image_urls: content.image_urls,
          corroborate_judgment_flags: true,
          check_off_platform_fulfillment: check_off_platform_fulfillment?,
        ),
      ]

      threads = strategies.map do |strategy|
        Thread.new do
          # Silence Ruby's stderr dump on thread death; Thread#value re-raises for the caller.
          Thread.current.report_on_exception = false
          strategy.perform
        end
      end

      threads.map(&:value)
    end

    # Only ask about off-platform fulfillment when the product genuinely has
    # nothing for the buyer to receive on Gumroad: no uploaded files (at the
    # product level or on any of its variants/tiers), no written or embedded
    # content, no Gumroad-managed integration (a Discord or Circle invite IS
    # the deliverable, and Gumroad itself provisions it on purchase), and not a
    # type whose deliverable is inherently something other than content (a call
    # is a scheduled meeting, a commission is work the seller performs, a
    # coffee/tip has no deliverable by design, a physical product ships, a
    # bundle delivers its component products). Checking this first means a
    # listing with real content can never be blocked by this preset no matter
    # how the description mentions Telegram or Discord — the preset is about
    # empty listings that route buyers off-platform, and the emptiness half of
    # that is decided here in code rather than by a model.
    def check_off_platform_fulfillment?
      return false unless entity_type == :product

      !product_has_deliverable?
    end

    # Whether the product holds rich content a buyer could actually read.
    #
    # Deliberately NOT `Link#has_content?`: that helper counts a rich content
    # record as content whenever its description array is non-empty, and the
    # product editor persists a blank placeholder paragraph for a content page
    # the seller never typed into. Under `has_content?` a completely empty
    # listing therefore looks like it has content and would skip this preset
    # entirely — which is one of the exact shapes the preset exists to catch.
    # `RichContent#has_editor_content?` is the predicate that knows a bare
    # paragraph is not readable content, while treating a page the seller gave a
    # title as real work (the title renders in the buyer's page list).
    #
    # Both levels are checked regardless of which one currently owns the
    # content, so a listing whose real pages live on a variant/tier keeps the
    # preset off just as a product-level page does.
    def has_reader_visible_content?(product)
      product.alive_rich_contents.any?(&:has_editor_content?) ||
        product.alive_variants.any? { |variant| variant.alive_rich_contents.any?(&:has_editor_content?) }
    end

    # A product that sells access to a Discord server or Circle community has
    # no files and no rich content by design: the buyer receives an invite that
    # Gumroad sends and records (PurchaseIntegration) on purchase. That's a
    # deliverable on Gumroad, so such a listing must never be handed to the
    # preset — its description legitimately reads like "buy this to join my
    # Discord".
    def gumroad_managed_integration?
      record.active_integrations.exists? ||
        record.alive_variants.any? { |variant| variant.active_integrations.exists? }
    end

    # `blocked: false` records a flag that did not stop the publish (e.g. a
    # spam flag that failed corroboration) so admins can still review it and
    # so downgraded flags stay countable against blocked ones.
    def leave_admin_comment(reasons, blocked: true)
      return if user.blank?
      # The dry-run preview endpoints validate an unsaved candidate to tell an
      # agent what a publish WOULD do. Nothing was published, so a note here
      # would let an agent iterating on borderline copy accrue moderation history
      # against the seller for content that never went live — and the preview
      # response already carries the reason back to the caller. Keyed on the
      # explicit flag rather than `new_record?`, which is also true for a real
      # create.
      return if record.try(:moderation_preview)

      record_label = case entity_type
                     when :product then "Product ##{record.id} (#{record.name})"
                     when :post then "Post ##{record.id} (#{record.name})"
                     when :page then "Page ##{record.id} (#{page_label})"
      end

      action = blocked ? "blocked publish of" : "flagged but did not block"
      content = "Content moderation #{action} #{record_label}: #{reasons.join("; ")}"
      # Created via a background job, not inline: this check runs inside the
      # blocked record's save transaction, and the failed save's rollback
      # would erase a synchronously created comment. The Sidekiq push happens
      # outside the DB transaction, so the note survives. The job also
      # dedupes identical notes within ADMIN_COMMENT_DEDUP_WINDOW.
      ContentModerationAdminCommentJob.perform_async(user.id, content)
    rescue StandardError => e
      Rails.logger.error("ContentModeration failed to leave admin comment: #{e.message}")
    end

    def user
      @user ||= case entity_type
                when :product then record.user
                when :post then record.user
                when :page then record.seller
      end
    end

    # Which page an admin note is about. A page has no name; the root takeover
    # has no slug either, so it is identified by the surface it replaces.
    def page_label
      return "#{record.slug} — #{record.title}" if record.slugged?

      record.pageable.is_a?(User) ? "profile page" : "product page for ##{record.pageable_id}"
    end
end
