# frozen_string_literal: true

# Tells sellers about video files that can never be played, so they can fix them
# themselves by re-uploading.
#
# A video file whose analysis finished without a width or a height is stuck
# forever: Streamable#transcodable? requires both dimensions, so the transcoder
# always bails out without creating a streaming version, while analyze_completed
# marks the file as done so nothing ever re-analyzes it. The customer just sees a
# lesson that never plays, and until now nobody told the seller. The only fix is
# the seller replacing the upload, which is why this job exists — the platform
# cannot repair the file.
#
# Runs daily. Files are grouped per product so a seller with several broken
# lessons in one course gets one email listing them, not one email per file. Each
# file is stamped once notified (unplayable_video_notified_at) so a later run
# does not email about it again; replacing the upload clears the condition
# because a successful re-analysis fills the dimensions in.
class NotifySellersOfUnplayableVideoFilesJob
  include Sidekiq::Job

  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  BATCH_SIZE = 500
  # Cap on emails per run so the first run does not send the entire accumulated
  # backlog in one burst. Anything left over is picked up by the next daily run.
  MAX_EMAILS_PER_RUN = 200

  def perform
    emails_sent = 0

    ProductFile.unplayable_video
      .joins(:link)
      .where(links: { deleted_at: nil })
      .find_in_batches(batch_size: BATCH_SIZE) do |batch|
      ReplicaLagWatcher.watch

      not_yet_notified = batch.reject { |product_file| product_file.unplayable_video_notified_at.present? }
      not_yet_notified.group_by(&:link_id).each do |link_id, product_files|
        return if emails_sent >= MAX_EMAILS_PER_RUN

        notify(link_id, product_files)
        emails_sent += 1
      end
    end
  end

  private
    def notify(link_id, product_files)
      # Stamping before the email is deliberate: a duplicate stamp costs the
      # seller nothing, whereas stamping afterwards risks emailing the same
      # files again if the job dies between the two steps.
      product_files.each do |product_file|
        product_file.unplayable_video_notified_at = Time.current
        product_file.save!
      end

      ContactingCreatorMailer.unplayable_video_files(link_id, product_files.map(&:id)).deliver_later(queue: "low")
    end
end
