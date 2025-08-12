# frozen_string_literal: true

class ChapterFileSizeWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(chapter_file_id)
    file = ChapterFile.find_by(id: chapter_file_id)
    return if file.nil?

    file.calculate_size
  end
end
