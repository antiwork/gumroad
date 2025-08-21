# frozen_string_literal: true

class RemoveAudioFromWebmWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :default

  def perform(record_id, record_type = "Thumbnail")
    ActiveRecord::Base.connection.stick_to_primary!
    Rails.logger.info "RemoveAudioFromWebmWorker: performing for #{record_type}_id=#{record_id}"

    record = record_type.constantize.find(record_id)
    return unless record.file.attached?
    return unless record.file.content_type == "video/webm"

    # Download the file to a temporary location
    temp_file = download_to_temp(record.file)
    return unless temp_file

    begin
      # Create output file path
      output_file = temp_file.path.sub(/\.webm$/, '_no_audio.webm')

      # Use FFmpeg to remove audio track
      movie = FFMPEG::Movie.new(temp_file.path)

      # Transcode the video without audio
      movie.transcode(output_file, { audio_codec: "none" })

      # Upload the processed file back to ActiveStorage
      record.file.attach(
        io: File.open(output_file),
        filename: record.file.filename,
        content_type: "video/webm"
      )

      Rails.logger.info "RemoveAudioFromWebmWorker: successfully removed audio from #{record_type} #{record_id}"
    rescue => e
      Rails.logger.error "RemoveAudioFromWebmWorker: failed to remove audio from #{record_type} #{record_id}: #{e.message}"
      raise e
    ensure
      # Clean up temporary files
      temp_file.close
      temp_file.unlink
      File.delete(output_file) if File.exist?(output_file)
    end
  end

  private

  def download_to_temp(attachment)
    require 'tempfile'

    temp_file = Tempfile.new(['webm_thumbnail', '.webm'])
    temp_file.binmode

    attachment.open do |file|
      temp_file.write(file.read)
    end

    temp_file.rewind
    temp_file
  rescue => e
    Rails.logger.error "RemoveAudioFromWebmWorker: failed to download file: #{e.message}"
    temp_file&.close
    temp_file&.unlink
    nil
  end
end
