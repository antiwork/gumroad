# frozen_string_literal: true

class AudienceExportMailer < ApplicationMailer
  default from: 'no-reply@gumroad.com'

  def export_ready(export, csv_path, filename)
    @export = export
    attachments[filename] = { mime_type: "text/csv", content: File.binread(csv_path)}
    mail(
      to: export.recipient.email,
      subject: "Your audience export is ready"
    )
  end
end
