# frozen_string_literal: true

class Exports::Audience::CompileChunksWorker
  include Sidekiq::Job
  # This job is unique because two parallel ProcessChunkWorker jobs could queue this at the same time.
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(export_id)
    @export = AudienceExport.find(export_id)

    tempfile = generate_compiled_tempfile
    filename = generate_filename

    ContactingCreatorMailer.subscribers_data(
      recipient: @export.recipient,
      tempfile:,
      filename:,
    ).deliver_now

    @export.chunks.in_batches(of: 1).delete_all
    @export.destroy!
  end

  private
    def generate_compiled_tempfile
      tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

      # The purpose of this enumerator is to allow the code to call `#each` on it,
      # yielding an individual [email, min_created_at] pair,
      # while never loading more than one chunk in memory (because of `find_each(batch_size: 1)`).
      audience_data_enumerator = Enumerator.new do |yielder|
        @export.chunks.select(:id, :audience_data).find_each(batch_size: 1) do |chunk|
          chunk.audience_data.each do |data|
            yielder << data
          end
        end
      end

      CsvSafe.open(tempfile, "wb", headers: Exports::AudienceExportService::FIELDS, write_headers: true) do |csv|
        audience_data_enumerator.each do |email, min_created_at|
          csv << [email, min_created_at]
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

