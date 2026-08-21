# frozen_string_literal: true

class ContentModeration::ModerateRecordService
  AUTHOR_NAME = "ContentModeration"
  ADMIN_COMMENT_DEDUP_WINDOW = 5.minutes

  STORAGE_CHECK_TIME_BUDGET_SECONDS = 2.0

  # One budget shared by a product and every variant it carries, so a save spends one
  # budget however many file lists it contains and logs one warning rather than one per tier.
  #
  # Tracked by file id, not counted: a file attached to a tier also belongs to the product
  # (`ProductFile#link_id` points at the product either way), so both lists walk it and
  # counting would double-report.
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

  # A page carrying more images than we will review is rejected rather than
  # approved on a sample (see `check`), so the reason is about the page's size,
  # not its content, and gets its own sentence saying what to change.
  TOO_MANY_IMAGES_REASON_PREFIX = "too many images to review"

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
    unsupported = ContentModeration::Strategies::ClassifierStrategy::UNSUPPORTED_IMAGE_REASON
    if rs.any? && rs.all? { |r| r.to_s.include?(transient) }
      "We couldn’t review this #{noun} just now (a temporary issue on our end). Please try again in a few minutes."
    elsif rs.any? && rs.all? { |r| r.to_s.include?(unsupported) }
      # Unlike the transient branch above, retrying can never fix this: the
      # image itself is something our review can’t read, so the seller has to
      # change it and the copy has to say so.
      #
      # Format and size are both named, and no byte figure is quoted: the two
      # ceilings differ (MAX_DATA_IMAGE_BYTES for an inline payload, OpenAI's
      # own limit for a URL it downloads), so one number here would be wrong for
      # whichever case the seller is actually in. "Smaller" is what they can act
      # on either way.
      "This #{noun} includes an image we can’t review, because the format is unsupported (such as an SVG data URL) " \
      "or the file is too large. Replace it with a smaller PNG, JPEG, GIF, or WebP and try again."
    elsif rs.any? { |r| r.to_s.start_with?(TOO_MANY_IMAGES_REASON_PREFIX) }
      "This #{noun} has more images than we can review, so we can’t publish it as is. " \
      "Reduce it to at most #{ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS} images " \
      "(or split it across several #{noun}s) and try again."
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

  def self.check(record, entity_type, skip_images: false)
    new(record, entity_type, skip_images:).check
  end

  def self.off_platform_fulfillment_reason?(reason)
    reason.to_s.start_with?("off_platform_fulfillment:")
  end
  private_class_method :off_platform_fulfillment_reason?

  def initialize(record, entity_type, skip_images: false)
    @record = record
    @entity_type = entity_type
    @skip_images = skip_images
  end

  def check
    return CheckResult.new(passed: true, reasons: []) unless moderation_enabled?
    return CheckResult.new(passed: true, reasons: []) if user&.verified?
    return CheckResult.new(passed: true, reasons: []) if record_moderation_disabled?

    content = extract_content
    content = content.class.new(text: content.text, image_urls: []) if @skip_images
    return CheckResult.new(passed: true, reasons: []) if content.text.blank? && content.image_urls.empty?

    previous_page_urls = previous_page_image_urls
    if entity_type == :page && content.image_urls.size > ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS
      if preexisting_over_budget_without_growth?(content, previous_page_urls)
        # A live storefront catalog that already exceeds the cap must stay
        # editable (1:1 cover swaps, copy tweaks) without raising the cap for
        # new pages. Only newly introduced URLs are reviewed.
        new_urls = content.image_urls - previous_page_urls
        content = content.class.new(text: content.text, image_urls: new_urls)
      else
        # Approving a page approves what it DISPLAYS, so it is rejected rather than
        # approved on a sample of its images.
        reasons = ["#{TOO_MANY_IMAGES_REASON_PREFIX} (#{content.image_urls.size})"]
        # `blocked: false`: the publish did stop, but the admin trail is read as
        # abuse history, and a seller with a big gallery has not done anything
        # wrong. The seller-facing message says what to change.
        leave_admin_comment(reasons, blocked: false)
        return CheckResult.new(passed: false, reasons: reasons)
      end
    end

    blocklist_result = ContentModeration::Strategies::BlocklistStrategy
                         .new(text: content.text, image_urls: content.image_urls)
                         .perform

    if blocklist_result.status == "flagged"
      leave_admin_comment(blocklist_result.reasoning)
      return CheckResult.new(passed: false, reasons: blocklist_result.reasoning)
    end

    ai_results = run_ai_strategies(content)
    flagged = ai_results.select { |r| r.status == "flagged" }

    # Judgment-preset flags (spam, off-platform fulfillment, and adult content the
    # model judged on text alone) that didn't reproduce when PromptStrategy
    # resampled them. They don't block the publish, but we still leave a note so
    # the flag rate and false-positive rate can be measured against blocked
    # publishes.
    audit_reasons = ai_results.flat_map { |r| r.respond_to?(:audit_reasoning) ? Array(r.audit_reasoning) : [] }

    reasons = flagged.flat_map(&:reasoning)

    # Order matters: `spam_flag_should_not_block?` can spend a two-second storage budget and
    # log a "ran out of time" warning, so never ask it unless there is a spam flag to downgrade.
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
      # An account-level exemption is a decision about the seller and their genre, so it
      # has to cover products that don't exist yet -- the per-record flag only ever covers
      # the catalogue as it stood when support granted it. It is scoped to products
      # deliberately: posts are not part of the catalogue an exemption is granted over, so
      # an exempt seller's posts still go through moderation.
      when :product then user&.content_moderation_disabled? || record.content_moderation_disabled?
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

    # The spam preset fires on the info-product writing STYLE (all-caps headline, benefit
    # bullets, earnings framing), not on anything that makes a listing actually spam. What
    # separates the two is whether the listing DELIVERS anything: link farms and fake listings
    # have nothing attached. So a product with a deliverable keeps the flag as a reviewable
    # note and publishes; an empty one still blocks, as do all the other presets, which key on
    # concrete content rather than tone (gumroad-private#1358).
    #
    # A page has no deliverable of its own, so the storefront stands in for it: live products
    # or completed sales mean the page is plausibly selling something, while a seller with
    # neither is the link-farm-on-a-gumroad.com-subdomain shape this exists to stop. Posts have
    # no deliverable either and are not covered here, so a spam flag on a post always blocks.
    def spam_flag_should_not_block?
      return seller_has_storefront? if entity_type == :page

      entity_type == :product && product_has_substantive_deliverable?
    end

    # Why an admin is reading a downgraded spam flag rather than a block.
    def spam_downgrade_note_reason
      entity_type == :page ? "not blocked: seller has a live storefront" : "not blocked: listing has content attached"
    end

    # Kept to two indexed existence checks: this runs inside a save.
    def seller_has_storefront?
      return false if user.blank?

      user.links.alive.exists? || user.sales.successful.exists?
    end

    # The stricter half of "does this listing deliver anything". Distinct from
    # `product_has_deliverable?`, which is generous on purpose because it only gates a QUESTION
    # we ask a model; here the same generosity would let a listing publish, so states a spammer
    # gets for free do NOT count: a page with only a title, an empty bundle, a coffee/tip
    # listing, a file whose upload never finished, and integrations Gumroad does not fulfil on
    # purchase (only a Circle/Discord invite IS the deliverable; Zoom and Google Calendar are
    # scheduling plumbing).
    def product_has_substantive_deliverable?
      return true if record.is_physical?
      return true if record.is_bundle? && record.bundle_products.alive.any?
      return true if record.native_type.in?([Link::NATIVE_TYPE_CALL, Link::NATIVE_TYPE_COMMISSION])
      return true if gumroad_fulfilled_community_integration?

      # One budget for the whole product, not one per file list — otherwise the worst case
      # multiplies by the number of variants a single save can contain.
      budget = StorageCheckBudget.new(seconds: STORAGE_CHECK_TIME_BUDGET_SECONDS)

      found_file = has_deliverable_file?(record, budget:) ||
        record.alive_variants.any? { |variant| has_deliverable_file?(variant, budget:) }

      # Readable page content establishes a deliverable on its own, so a product
      # that has some passes whether or not we got through its files.
      has_deliverable = found_file || has_readable_body_content?(record)

      # So a rejection that only means "we ran out of time" is explicable from the logs. Its
      # position is deliberate: outside the per-list check (one line per save, not per tier),
      # and after the page-content half, so a product that ran out of budget on files but
      # passed on content carries no failure-shaped warning.
      if !has_deliverable && budget.unchecked_file_count.positive?
        Rails.logger.warn(
          "ContentModeration: storage check budget spent with " \
          "#{budget.unchecked_file_count} unverifiable file(s) left unchecked on " \
          "#{record.class.name} ##{record.id}"
        )
      end

      has_deliverable
    end

    # An attached file counts only when something is really in storage behind it. An alive
    # `ProductFile` row is not proof: a save racing an unfinished multipart upload leaves a row
    # pointing at a key that was never written, and nothing deletes it afterwards (see
    # `ProductFile#stored_file_present?`). The save API takes each file's storage URL from the
    # client, so a caller can submit arbitrarily many such rows.
    #
    # Most rows answer for themselves (analyzed file, external link, purged object) and are
    # settled for free; only the rest cost a storage request. Those are capped by TIME, not by
    # file count, because a count cap must pick a slice and the caller controls the list — any
    # slice can be pushed off a real file by padding. It also can't be fixed by ordering: a
    # genuinely stored file can be unverifiable at either end of creation order (uploaded
    # moments ago before AnalyzeFileWorker ran, or analysis that will never succeed — retries
    # exhausted, or a video whose metadata can't be read, see
    # `WithFileProperties#video_analysis_failed`, which nothing revisits). Newest-first is still
    # the right order: the freshly-uploaded file usually answers on the first request.
    #
    # An exhausted budget FAILS the check on purpose — "we don't know" must not pass, or the
    # bypass reopens. It can only make an honest seller cheaper to confirm; passing always
    # requires an object actually in storage.
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

    # Rich content with something in the body, ignoring title-only pages (see
    # `product_has_substantive_deliverable?`) and blocks that deliver nothing themselves: a
    # `posts` block with no published posts and a `fileEmbed` pointing at a missing file render
    # nothing, and recommendations, upsells and form fields ask something OF the buyer. Each is
    # one click to insert. A genuinely attached file is still covered, by the
    # `alive_product_files` checks in `product_has_substantive_deliverable?`.
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

    def previous_page_image_urls
      return [] unless entity_type == :page && record.is_a?(Page) && record.persisted?

      snapshot = record.dup
      snapshot.custom_html = record.custom_html_was
      snapshot.content = record.content_was if record.has_attribute?(:content)
      ContentModeration::ContentExtractor.new.extract_from_page(snapshot).image_urls
    end

    def preexisting_over_budget_without_growth?(content, previous_urls)
      previous_urls.size > ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS &&
        content.image_urls.size <= previous_urls.size
    end

    def run_ai_strategies(content)
      strategies = [
        ContentModeration::Strategies::ClassifierStrategy.new(
          text: content.text,
          image_urls: content.image_urls,
          # A page's images are arbitrary URLs the seller wrote into a public
          # document, and the page is only allowed through if all of them were
          # reviewed (`check` rejects a page over the budget), so every one gets a
          # moderation attempt. Products and posts keep the default cap: their
          # images come from our own uploads and their galleries are unbounded.
          max_images: entity_type == :page ? :all : ContentModeration::Strategies::ClassifierStrategy::MAX_IMAGES_TO_MODERATE,
        ),
        # `corroborate_judgment_flags` makes a spam, off-platform-fulfillment, or
        # text-only adult-content flag block only when it reproduces on resampling;
        # a lone flag is returned as audit_reasoning and recorded as a non-blocking
        # note instead (see `check` above).
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

    # The preset is about EMPTY listings that route buyers off-platform, so the emptiness half
    # is decided here in code rather than by a model. Gating on it first means a listing with
    # real content can never be blocked by this preset however its description mentions
    # Telegram or Discord.
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
