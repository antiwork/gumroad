# frozen_string_literal: true

class Pages::GeneratePageVersionJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(page_id, prompt, parent_version_id = nil)
    page = Page.find(page_id)
    parent_version = parent_version_id ? PageVersion.find_by(id: parent_version_id) : nil

    # Clear any previous error so the polling endpoint sees generating=true.
    page.update_columns(generation_error: nil, generating_since: Time.current)

    moderation = ContentModeration::ModerateRecordService.check(page, :page)
    unless moderation.passed
      Rails.logger.warn("Pages::GeneratePageVersionJob skipped page=#{page.id} reasons=#{moderation.reasons.join('; ')}")
      page.update_columns(generation_error: "Content moderation failed — try a different prompt.", generating_since: nil)
      return
    end

    result = Ai::PageGeneratorService.new(
      page: page,
      seller: page.user,
      prompt: prompt,
      parent_version: parent_version,
    ).call

    if result.success?
      # Write content first, then flip generating off in the same UPDATE so a
      # poll tick can't see generating=false with stale html_content.
      page.apply_new_version!(result.version)
      page.update_column(:generating_since, nil)
    else
      page.update_columns(generation_error: "Generation failed — please try again.", generating_since: nil)
    end
  ensure
    # Belt-and-suspenders for any unhandled error path: never leave the row
    # stuck in the "generating" state. Safe to call when page is nil (find
    # raised) — guarded below.
    page&.update_column(:generating_since, nil) if page&.persisted? && page&.generating_since.present?
  end
end
