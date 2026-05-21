# frozen_string_literal: true

class Pages::GeneratePageVersionJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(page_id, prompt, parent_version_id = nil)
    page = Page.find(page_id)
    parent_version = parent_version_id ? PageVersion.find_by(id: parent_version_id) : nil

    # Clear any previous error so the polling endpoint sees generating=true.
    page.update_column(:generation_error, nil)

    moderation = ContentModeration::ModerateRecordService.check(page, :page)
    unless moderation.passed
      Rails.logger.warn("Pages::GeneratePageVersionJob skipped page=#{page.id} reasons=#{moderation.reasons.join('; ')}")
      page.update_column(:generation_error, "Content moderation failed — try a different prompt.")
      return
    end

    result = Ai::PageGeneratorService.new(
      page: page,
      seller: page.user,
      prompt: prompt,
      parent_version: parent_version,
    ).call

    if result.success?
      page.apply_new_version!(result.version)
    else
      page.update_column(:generation_error, "Generation failed — please try again.")
    end
  end
end
