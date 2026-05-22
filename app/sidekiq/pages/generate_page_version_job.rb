# frozen_string_literal: true

class Pages::GeneratePageVersionJob
  include Sidekiq::Job

  # Retry transient OpenAI failures (timeouts, 5xx, 429). Permanent errors
  # (moderation rejection, 4xx) return early without raising so they don't
  # consume retries. The `ensure` block clears `generating_since` on every
  # attempt — including the final failed one — so the page never gets stuck
  # in the "generating" state.
  #
  # `lock: :until_executed` deduplicates by job digest (page id + prompt +
  # parent) so a user repeatedly re-firing the same generation request can't
  # stack up identical OpenAI calls. Queued on `:low` because generation is
  # not time-critical and we want it to share fate with the rest of low-prio
  # work rather than competing with payment/email traffic on `:default`.
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  sidekiq_retries_exhausted do |msg, _ex|
    page_id = msg["args"]&.first
    page = Page.find_by(id: page_id) if page_id
    page&.update_columns(
      generation_error: "Generation failed — please try again.",
      generating_since: nil,
    )
  end

  def perform(page_id, prompt, parent_version_id = nil)
    page = Page.find(page_id)
    parent_version = parent_version_id ? PageVersion.find_by(id: parent_version_id) : nil

    # Clear any previous error so the polling endpoint sees generating=true.
    page.update_columns(generation_error: nil, generating_since: Time.current)

    result = Ai::PageGeneratorService.new(
      page: page,
      seller: page.user,
      prompt: prompt,
      parent_version: parent_version,
    ).call

    unless result.success?
      page.update_columns(generation_error: "Generation failed — please try again.", generating_since: nil)
      return
    end

    # Apply the version first so output moderation sees the freshly generated
    # HTML — not the previous html_content. The prompt was moderated in the
    # controller before enqueuing; this is the output-side check.
    applied = page.apply_new_version!(result.version, expected_parent_id: parent_version&.id)
    unless applied
      # A newer generation has been applied while this job was running.
      # Discard the stale apply silently — surfacing an error would
      # confuse the user, whose newer prompt has already produced output.
      Rails.logger.info("Pages::GeneratePageVersionJob skipped stale apply page=#{page.id} parent=#{parent_version&.id}")
      page.update_column(:generating_since, nil)
      return
    end
    moderation = ContentModeration::ModerateRecordService.check(page, :page)
    unless moderation.passed
      Rails.logger.warn("Pages::GeneratePageVersionJob output moderation failed page=#{page.id} reasons=#{moderation.reasons.join('; ')}")
      page.update_columns(generation_error: "Content moderation failed — try a different prompt.", generating_since: nil)
      return
    end

    # Write content first, then flip generating off in the same UPDATE so a
    # poll tick can't see generating=false with stale html_content.
    page.update_column(:generating_since, nil)
  ensure
    # Belt-and-suspenders for any unhandled error path: never leave the row
    # stuck in the "generating" state. Safe to call when page is nil (find
    # raised) — guarded below. Runs on every attempt, so transient retries
    # don't leave generating_since stale between attempts either.
    page&.update_column(:generating_since, nil) if page&.persisted? && page&.generating_since.present?
  end
end
