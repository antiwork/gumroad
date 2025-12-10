# frozen_string_literal: true

class Exports::Audience::CompileChunksWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze

  def perform(export_id)
    @export = AudienceExport.find(export_id)

    tempfile = generate_compiled_tempfile
    filename = generate_filename

    ContactingCreatorMailer.subscribers_data(
      recipient: @export.recipient,
      tempfile:,
      filename:
    ).deliver_now

    @export.chunks.in_batches(of: 1).delete_all
    @export.destroy!
  end

  private
    def generate_compiled_tempfile
      tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

      CSV.open(tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
        @export.chunks.select(:id, :csv_data).find_each(batch_size: 1) do |chunk|
          chunk.csv_data.each do |row|
            csv << row
          end
        end
      end

      tempfile.rewind
      tempfile
    end

    def generate_filename
      timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
      "Subscribers-#{@export.seller.username}_#{timestamp}.csv"
    end
end
