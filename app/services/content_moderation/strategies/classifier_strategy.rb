# frozen_string_literal: true

class ContentModeration::Strategies::ClassifierStrategy
  Result = Struct.new(:status, :reasoning, keyword_init: true)
  OPENAI_REQUEST_TIMEOUT_IN_SECONDS = 10
  # A batch carries up to IMAGES_PER_REQUEST downloads on OpenAI's side, so it
  # gets a longer budget than a single input would. Only the multi-input request
  # uses it — single-image calls stay on the 10s budget, because the fallback
  # path fires routinely (an expired signed product URL 400s its batch) and
  # tripling its timeout would triple that save's worst case.
  IMAGE_BATCH_REQUEST_TIMEOUT_IN_SECONDS = 30
  MAX_MODERATION_ATTEMPTS = 3
  # Wall-clock ceiling on the whole image phase. This runs inside the record's
  # save, and for a page inside `with_lock` on the users row that payout
  # processing also locks (Pages::CustomHtmlWriter), so an OpenAI degradation
  # must not turn one save into minutes of held lock: without this, 25 images
  # whose batches all time out and then retry individually is ~40 minutes.
  # Expiring fails closed — the images that were not reached are unmoderated,
  # which is the same state as an unreachable service.
  IMAGE_PHASE_DEADLINE_IN_SECONDS = 60
  # How many images one save spends a moderation attempt on when the caller
  # doesn't say otherwise (products and posts, whose image sets come from our own
  # uploads rather than arbitrary seller HTML).
  MAX_IMAGES_TO_MODERATE = 5
  # The moderations endpoint takes an array of inputs and returns one result per
  # input, which is what makes moderating every image a page displays affordable.
  IMAGES_PER_REQUEST = 5
  # Ceiling on one inline `data:image/` payload. A page can carry 500k characters
  # of HTML, so without this a handful of inline images would build a request far
  # over what the endpoint accepts and 400 the batch. Over the ceiling counts as
  # unmoderated (which blocks a full-coverage caller) rather than as absent.
  MAX_DATA_IMAGE_BYTES = 200_000
  # Distinguishes "the deadline passed before we asked about this image" from
  # "we asked and OpenAI would not answer" (nil). Both leave the image
  # unmoderated and both block a full-coverage caller; only the logs differ.
  UNREACHED = :unreached
  # A payload the endpoint deterministically refuses. Blocks a full-coverage
  # caller like nil/UNREACHED, but must not read as transient: the input is
  # static, so "try again later" can never come true.
  UNSUPPORTED = :unsupported
  PERMANENT_REJECTION_CODES = %w[invalid_data_url invalid_image_format file_too_large].freeze
  # The raw (unsigned) private-bucket prefix — what `gumroad-cli files upload`
  # and other API::V2::FilesController writes hand back. OpenAI 400s fetching
  # it with `image_url_unavailable` every time (403, not a signed-URL expiry),
  # so unlike the same code on a product/post's expired signed URL, a retry
  # here can never succeed.
  UNFETCHABLE_PRIVATE_BUCKET_URL_PREFIX = S3_BASE_URL
  UNAVAILABLE_REASON = "We cannot moderate the content at this time, please try again later or update the content."
  # Not "inline": `file_too_large` reaches here for a remote URL OpenAI
  # downloaded and refused, not only for a `data:` payload we refused locally.
  UNSUPPORTED_IMAGE_REASON = "The content contains an image the moderation endpoint cannot review (unsupported format or too large)."

  DEFAULT_THRESHOLDS = {
    "harassment" => 0.8,
    "harassment/threatening" => 0.8,
    "hate" => 0.8,
    "hate/threatening" => 0.8,
    "illicit" => 0.8,
    "illicit/violent" => 0.8,
    "self-harm" => 0.8,
    "self-harm/intent" => 0.8,
    "self-harm/instructions" => 0.8,
    "sexual" => 0.8,
    "sexual/minors" => 0.3,
    "violence" => 0.9,
    "violence/graphic" => 0.9,
  }.freeze

  # `max_images:` is how many images this content is allowed to spend moderation
  # attempts on. `:all` means every image — used by pages, where the images are
  # arbitrary URLs the seller wrote into a public document and approving the page
  # on a subset would approve whatever the rest displays.
  def initialize(text:, image_urls: [], max_images: MAX_IMAGES_TO_MODERATE)
    @text = text
    @image_urls = image_urls
    @max_images = max_images
  end

  def perform
    return Result.new(status: "compliant", reasoning: []) if @text.blank? && @image_urls.empty?

    api_key = GlobalConfig.get("OPENAI_ACCESS_TOKEN")
    return Result.new(status: "compliant", reasoning: []) if api_key.blank?

    @api_key = api_key
    @client = OpenAI::Client.new(access_token: api_key, request_timeout: OPENAI_REQUEST_TIMEOUT_IN_SECONDS)
    @image_client = OpenAI::Client.new(access_token: api_key, request_timeout: IMAGE_BATCH_REQUEST_TIMEOUT_IN_SECONDS)
    thresholds = load_thresholds

    flagged_categories = []
    text_moderated = false

    if @text.present?
      scores = moderate([{ type: "text", text: @text }])
      if scores.nil?
        return Result.new(status: "flagged", reasoning: [UNAVAILABLE_REASON])
      end
      text_moderated = true
      flagged_categories.concat(collect_flagged(scores, thresholds))
    end

    moderated_count = 0
    skipped_urls = []
    unreached_urls = []
    unsupported_urls = []
    # See ContentModeration::ImageSelection for why this order, not a shuffle.
    # Walking it (rather than taking the first MAX) means an image OpenAI refuses
    # to fetch falls through to the next instead of costing a slot.
    urls_to_moderate = ContentModeration::ImageSelection.ordered(@image_urls)
    @image_phase_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + IMAGE_PHASE_DEADLINE_IN_SECONDS

    urls_to_moderate.each_slice(IMAGES_PER_REQUEST) do |batch|
      remaining = @max_images == :all ? batch.size : @max_images - moderated_count
      break if remaining <= 0

      selected = batch.first(remaining)
      if deadline_expired?
        unreached_urls.concat(selected)
        next
      end

      moderate_images(selected).each do |url, scores|
        if scores == UNREACHED
          unreached_urls << url
          next
        end

        if scores == UNSUPPORTED
          unsupported_urls << url
          next
        end

        if scores.nil?
          skipped_urls << url
          next
        end

        moderated_count += 1
        flagged_categories.concat(collect_flagged(scores, thresholds))
      end
    end

    # A concrete violation is more actionable than "try again later", so a real
    # flag is reported even if another image was unreviewable. Both block.
    if flagged_categories.any?
      return Result.new(
        status: "flagged",
        reasoning: flagged_categories.uniq.map { |cat| "OpenAI moderation flagged: #{cat}" }
      )
    end

    # A caller asking for every image is relying on full coverage for its verdict:
    # `ModerateRecordService` rejects a page over the image budget on the grounds
    # that the ones inside it were all reviewed. So for `:all`, an image we could
    # not moderate blocks rather than degrading to a text-only pass — otherwise a
    # single image on a host that serves browsers and refuses OpenAI publishes
    # unreviewed, which is the bypass the budget rejection exists to close.
    if @max_images == :all && (skipped_urls.any? || unreached_urls.any? || unsupported_urls.any?)
      Rails.logger.warn(
        "ContentModeration::ClassifierStrategy blocking full-coverage content: " \
        "#{skipped_urls.size} image(s) rejected by OpenAI, #{unsupported_urls.size} with an unreviewable payload, " \
        "#{unreached_urls.size} not reached within #{IMAGE_PHASE_DEADLINE_IN_SECONDS}s, of #{@image_urls.size}"
      )
      # "Try again later" only when a retry could plausibly change the outcome.
      # When every unmoderated image was a deterministic payload rejection, the
      # block is permanent and the reason has to send the seller at the image,
      # not at the clock.
      reason = skipped_urls.none? && unreached_urls.none? ? UNSUPPORTED_IMAGE_REASON : UNAVAILABLE_REASON
      return Result.new(status: "flagged", reasoning: [reason])
    end

    if @image_urls.any? && moderated_count == 0
      if text_moderated
        # Every image was rejected by OpenAI (usually an expired signed attachment
        # URL it could not download — an expected, recurring upstream condition),
        # but the text still got a full moderation pass. Log it for visibility
        # instead of paging Sentry: per-image failures that exhaust retries are
        # already reported individually inside #moderate, and this summary was
        # producing hundreds of noise events a month with no action to take.
        Rails.logger.warn(
          "ContentModeration::ClassifierStrategy could not moderate any image " \
          "(#{skipped_urls.size + unsupported_urls.size}/#{@image_urls.size} rejected by OpenAI); text was moderated, continuing with text-only result"
        )
      else
        # No text and no image could be moderated — the content got zero
        # evaluation and the seller is blocked. That is worth a Sentry report
        # so we notice if it spikes.
        ErrorNotifier.notify(
          "ContentModeration::ClassifierStrategy could not moderate any image",
          image_url_count: @image_urls.size,
          skipped_urls: (skipped_urls + unsupported_urls).map { |url| loggable_url(url) },
        )
        reason = skipped_urls.none? && unreached_urls.none? && unsupported_urls.any? ? UNSUPPORTED_IMAGE_REASON : UNAVAILABLE_REASON
        return Result.new(status: "flagged", reasoning: [reason])
      end
    end

    Result.new(status: "compliant", reasoning: [])
  rescue StandardError => e
    Rails.logger.error("ContentModeration::ClassifierStrategy error: #{e.message}")
    raise
  end

  private
    # One request per batch of image URLs, returning `[url, scores_or_nil]` pairs
    # in the order given. The endpoint answers an array of inputs with one result
    # per input, positionally.
    #
    # A single unfetchable URL 400s the WHOLE batch (a recurring upstream
    # condition: expired signed attachment URLs, hosts that block OpenAI), so a
    # rejected batch is retried one image at a time. Otherwise one bad image would
    # drop four good ones from the verdict — the failure mode this batching exists
    # to avoid.
    def moderate_images(urls)
      # An inline payload we will not send is unmoderated, not clean: reported as
      # UNSUPPORTED so a full-coverage caller still blocks on it, with copy that
      # names the image rather than a passing outage — the payload is static, so
      # no retry can shrink it.
      oversized, sendable = urls.partition { |url| oversized_data_image?(url) }
      if oversized.any?
        Rails.logger.warn(
          "ContentModeration::ClassifierStrategy skipping #{oversized.size} inline image(s) over " \
          "#{MAX_DATA_IMAGE_BYTES} bytes"
        )
      end
      refused = oversized.map { |url| [url, UNSUPPORTED] }

      return refused if sendable.empty?
      return refused + individually(sendable) if sendable.size == 1

      input = sendable.map { |url| { type: "image_url", image_url: { url: url } } }
      scores = moderate_batch(input)
      return refused + sendable.each_with_index.map { |url, index| [url, scores[index]] } unless scores.nil?

      refused + individually(sendable)
    end

    # The per-image fallback multiplies the phase: one failed batch becomes
    # `urls.size` requests, each with its own attempt budget.
    def individually(urls)
      urls.map do |url|
        next [url, UNREACHED] if deadline_expired?

        [url, moderate_one_image(url)]
      end
    end

    def deadline_expired?
      remaining_image_phase_seconds <= 0
    end

    def remaining_image_phase_seconds
      return Float::INFINITY if @image_phase_deadline.nil?

      @image_phase_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def oversized_data_image?(url)
      url.to_s.start_with?("data:") && url.to_s.bytesize > MAX_DATA_IMAGE_BYTES
    end

    # A `data:` image URL IS the image, so logging one verbatim would put a whole
    # base64 payload in the logs and in Sentry.
    def loggable_url(url)
      return url unless url.to_s.start_with?("data:")

      "#{url.to_s[0, 30]}…(#{url.to_s.bytesize} bytes inline)"
    end

    def moderate_one_image(url)
      moderate([{ type: "image_url", image_url: { url: url } }],
               skip_url: url,
               timeout: OPENAI_REQUEST_TIMEOUT_IN_SECONDS)
    end

    # Per-input category scores for a multi-input request, or nil when the whole
    # request failed and the caller should fall back to one image at a time.
    def moderate_batch(input)
      response = moderations(input, client: @image_client, timeout: IMAGE_BATCH_REQUEST_TIMEOUT_IN_SECONDS)
      results = response["results"]
      # A short results array would silently pair scores with the wrong URLs, and
      # a wrong-image verdict is worse than an unmoderated one: fall back.
      return nil unless results.is_a?(Array) && results.size == input.size

      # A slot without scores is an image we did NOT get a verdict for. Mapping it
      # to `{}` would read as "no category over threshold" — a clean pass for an
      # unreviewed image, and it would also count towards moderated_count and so
      # suppress the no-image-moderated safety net below.
      results.map { |result| result.is_a?(Hash) ? result["category_scores"] : nil }
    rescue Faraday::BadRequestError, Faraday::TimeoutError, Faraday::ConnectionFailed,
           Faraday::ParsingError, Faraday::ServerError => e
      Rails.logger.warn(
        "ContentModeration::ClassifierStrategy image batch of #{input.size} failed " \
        "(#{e.class.name.demodulize}), retrying images individually: #{e.message[0, 300]}"
      )
      nil
    end

    def moderate(input, skip_url: nil, timeout: nil, client: @client)
      attempts = 0
      begin
        attempts += 1
        response = moderations(input, client:, timeout:)
        scores = response.dig("results", 0, "category_scores")
        # A 200 whose payload carries no scores is an input we did NOT get a
        # verdict for. `{}` would read as "no category over threshold" — the same
        # clean-pass-for-an-unreviewed-image shape guarded in #moderate_batch.
        return nil unless scores.is_a?(Hash)

        scores
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ParsingError, Faraday::ServerError => e
        # Retrying past the phase deadline is the same overrun one level down: the
        # image is going to count as unmoderated either way, so spend nothing more
        # on it.
        stopped_by_deadline = deadline_expired?
        if attempts < MAX_MODERATION_ATTEMPTS && !stopped_by_deadline
          Rails.logger.warn("ContentModeration::ClassifierStrategy #{e.class.name.demodulize} on attempt #{attempts}/#{MAX_MODERATION_ATTEMPTS}, retrying: #{e.message}")
          retry
        end
        reason = stopped_by_deadline ? "image phase deadline expired" : "exhausted attempts"
        Rails.logger.warn("ContentModeration::ClassifierStrategy giving up after #{attempts}/#{MAX_MODERATION_ATTEMPTS} attempts (#{reason}): #{e.class} - #{e.message}")
        ErrorNotifier.notify(e, attempts: attempts, input_type: input.first[:type], skip_url: loggable_url(skip_url))
        nil
      rescue Faraday::BadRequestError => e
        raise if skip_url.nil?
        body = e.response&.dig(:body)
        Rails.logger.warn("ContentModeration::ClassifierStrategy skipping unmoderatable image URL=#{loggable_url(skip_url)} error=#{body.to_s[0..500]}")
        # A rejection of the payload itself (vs. a fetch OpenAI could not
        # perform) reproduces on every save of the same content, so it must not
        # be reported as a passing failure.
        code = body.is_a?(Hash) ? body.dig("error", "code") : nil
        return UNSUPPORTED if code == "image_url_unavailable" && skip_url.to_s.start_with?(UNFETCHABLE_PRIVATE_BUCKET_URL_PREFIX)

        PERMANENT_REJECTION_CODES.include?(code) ? UNSUPPORTED : nil
      end
    end

    # Issues one request, clamped to what is left of the image phase when the
    # caller declared a timeout. Without the clamp a request that starts a tenth
    # of a second inside the deadline still spends its full budget, so the phase
    # overruns by one request timeout per late image — and on a page that overrun
    # is time held `with_lock` on the users row, not merely slow moderation.
    def moderations(input, client:, timeout:)
      client = rebudgeted(client, timeout) if timeout
      client.moderations(parameters: { model: "omni-moderation-latest", input: })
    end

    def rebudgeted(client, timeout)
      remaining = remaining_image_phase_seconds
      return client if remaining >= timeout

      # Callers check the deadline before asking, so `remaining` is positive here;
      # the floor is only so a clock edge can't hand Faraday a zero budget, which
      # it reads as "no timeout" — the opposite of what this is for.
      OpenAI::Client.new(access_token: @api_key, request_timeout: [remaining, 0.001].max)
    end

    def collect_flagged(category_scores, thresholds)
      category_scores.filter_map do |category, score|
        threshold = thresholds[category]
        next if threshold.nil?
        next unless score >= threshold

        "#{category} (score: #{score.round(3)}, threshold: #{threshold})"
      end
    end

    def load_thresholds
      custom = GlobalConfig.get("CONTENT_MODERATION_CLASSIFIER_THRESHOLDS")
      if custom.present?
        DEFAULT_THRESHOLDS.merge(JSON.parse(custom))
      else
        DEFAULT_THRESHOLDS
      end
    rescue JSON::ParserError
      DEFAULT_THRESHOLDS
    end
end
