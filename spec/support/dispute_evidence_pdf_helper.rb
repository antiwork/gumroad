# frozen_string_literal: true

module DisputeEvidencePdfHelper
  # Path of a real PDF with exactly `page_count` pages, for browser uploads. The file is removed
  # after the example.
  def create_pdf_path(page_count)
    source = Rails.root.join("spec", "support", "fixtures", "test.pdf").to_s
    file = Tempfile.new(["dispute_evidence_#{page_count}_pages", ".pdf"])
    (@dispute_evidence_pdf_tempfiles ||= []) << file
    _stdout, stderr, status = Open3.capture3("qpdf", "--empty", "--pages", *([source] * page_count), "--", file.path)
    raise "qpdf failed: #{stderr}" unless status.success?

    file.path
  end

  # A real PDF with exactly `page_count` pages: test.pdf repeated through qpdf.
  def create_pdf_blob(page_count, filename: "customer_communication.pdf")
    source = Rails.root.join("spec", "support", "fixtures", "test.pdf").to_s
    Tempfile.create(["dispute_evidence_pages", ".pdf"]) do |file|
      _stdout, stderr, status = Open3.capture3("qpdf", "--empty", "--pages", *([source] * page_count), "--", file.path)
      raise "qpdf failed: #{stderr}" unless status.success?

      File.open(file.path) do |io|
        ActiveStorage::Blob.create_and_upload!(io:, filename:, content_type: "application/pdf")
      end
    end
  end
end

RSpec.configure do |config|
  config.include DisputeEvidencePdfHelper
  config.after { @dispute_evidence_pdf_tempfiles&.each(&:close!) }
end
