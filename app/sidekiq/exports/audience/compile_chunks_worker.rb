# frozen_string_literal: true

class Exports::Audience::CompileChunksWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(export_id)
    @export = AudienceExport.find(export_id)

    service = Exports::AudienceExportService.new(@export.user, @export.audience_options)
    filename = service.filename

    tempfile = generate_compiled_tempfile(service.class::FIELDS)

    ContactingCreatorMailer.subscribers_data(
      recipient: @export.recipient,
      tempfile: tempfile,
      filename: filename
    ).deliver_now

    @export.chunks.in_batches(of: 1).delete_all
    @export.destroy!
  end

  private
    def generate_compiled_tempfile(fields)
      tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

      CSV.open(tempfile, "wb", headers: fields, write_headers: true) do |csv|
        # Use find_each to avoid loading all chunks into memory
        @export.chunks.select(:id, :audience_members_data).find_each(batch_size: 1) do |chunk|
          chunk.audience_members_data.each do |row|
            csv << row
          end
        end
      end

      tempfile.rewind
      tempfile
    end
end
