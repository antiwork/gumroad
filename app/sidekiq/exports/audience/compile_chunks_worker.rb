# frozen_string_literal: true

require "csv"

class Exports::Audience::CompileChunksWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze

  def perform(export_id)
    export = AudienceExport.find(export_id)
    recipient = export.recipient
    seller = recipient.seller || recipient

    timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
    filename = "Subscribers-#{seller.username}_#{timestamp}.csv"

    tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

    begin
      CSV.open(tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
        export.chunks.order(:id).find_each do |chunk|
          chunk.members_data.each do |row|
            csv << row
          end
        end
      end

      tempfile.rewind

      ContactingCreatorMailer.subscribers_data(
        recipient: recipient,
        tempfile: tempfile,
        filename: filename
      ).deliver_now

    ensure
      tempfile.close
      tempfile.unlink

      export.destroy
    end
  end
end
