# frozen_string_literal: true

class Exports::CompileAudienceExportChunksJob
  include Sidekiq::Worker
  sidekiq_options retry: 3, queue: :low

  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze

  def perform(audience_export_id)
    export = AudienceExport.find(audience_export_id)
    tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")
    CsvSafe.open(tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
      export.audience_export_chunks.each do |chunk|
        Array(chunk.json_data['members_data']).each do |email, timestamp|
          csv << [email, timestamp]
        end
      end
    end
    tempfile.rewind
    # Send email using actual mailer
    AudienceExportMailer.export_ready(export, tempfile.path, export.filename).deliver_later
    tempfile.close
    tempfile.unlink
    export.audience_export_chunks.delete_all
    export.destroy!
  end
end
