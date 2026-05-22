# frozen_string_literal: true

class Pages::GeneratePageVersionJob
  include Sidekiq::Job

  # Retry transient OpenAI failures (timeouts, 5xx, 429). Permanent errors
  # (moderation rejection, 4xx) return early without raising so they don't
  # consume retries. The `ensure` block clears `generating_since` on every
  # attempt — including the final failed one — so the page never gets stuck
  # in the "generating" state.
  sidekiq_options retry: 3, queue: :default

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
    page.apply_new_version!(result.version)
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
