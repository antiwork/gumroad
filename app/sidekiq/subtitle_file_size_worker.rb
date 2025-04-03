# frozen_string_literal: true

class SubtitleFileSizeWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(subtitle_file_id)
    file = SubtitleFile.find_by(id: subtitle_file_id)
    return if file.nil?

    file.calculate_size
  end
end
