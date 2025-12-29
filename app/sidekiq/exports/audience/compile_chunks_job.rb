# frozen_string_literal: true

require "csv"

class Exports::Audience::CompileChunksJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze

  def perform(export_id)
    @export = AudienceExport.find(export_id)

    tempfile = generate_csv
    send_email(tempfile)
    cleanup
  end

  private
    def generate_csv
      timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
      @filename = "Subscribers-#{@export.seller.username}_#{timestamp}.csv"

      tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

      CSV.open(tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
        @export.chunks.order(:id).find_each(batch_size: 1) do |chunk|
          chunk.members_data&.each do |email, created_at|
            csv << [email, created_at]
          end
        end
      end

      tempfile.rewind
      tempfile
    end

    def send_email(tempfile)
      ContactingCreatorMailer.subscribers_data(
        recipient: @export.recipient,
        tempfile: tempfile,
        filename: @filename
      ).deliver_now
    end

    def cleanup
      @export.chunks.in_batches(of: 100).delete_all
      @export.destroy!
    end
end
