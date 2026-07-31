# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidence::MergeCustomerCommunicationFilesService do
  def create_blob(fixture, filename, content_type)
    ActiveStorage::Blob.create_and_upload!(
      io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", fixture), content_type),
      filename:,
      content_type:
    )
  end

  def pages(merged_blob)
    PDF::Reader.new(StringIO.new(merged_blob.download)).pages
  end

  def page_dimensions(merged_blob)
    pages(merged_blob).map do |page|
      media_box = page.attributes[:MediaBox]
      [(media_box[2] - media_box[0]).round, (media_box[3] - media_box[1]).round]
    end
  end

  let(:max_size) { DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE }

  before do
    # Purging in test ENV returns Aws::S3::Errors::AccessDenied
    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
  end

  it "merges images into a one-page-per-image PDF, preserving upload order" do
    blobs = [
      create_blob("autumn-leaves-1280x720.jpeg", "chat-1.jpeg", "image/jpeg"),
      create_blob("lemons-640x362.png", "chat-2.png", "image/png"),
      create_blob("smilie.png", "chat-3.png", "image/png"),
    ]

    merged_blob = described_class.perform(blobs:, max_size:)

    expect(merged_blob.content_type).to eq("application/pdf")
    expect(merged_blob.filename.to_s).to eq("customer_communication.pdf")
    expect(merged_blob.byte_size).to be <= max_size
    # Each page is sized to its source image, so the page dimensions prove the order.
    expect(page_dimensions(merged_blob)).to eq([[1280, 723], [640, 362], [1006, 1006]])
  end

  it "carries all pages of input PDFs through the merge" do
    blobs = [
      create_blob("billion-dollar-company-chapter-0.pdf", "chapter.pdf", "application/pdf"), # 6 pages
      create_blob("smilie.png", "screenshot.png", "image/png"),
      create_blob("test.pdf", "receipt.pdf", "application/pdf"), # 1 page
    ]

    merged_blob = described_class.perform(blobs:, max_size:)

    expect(pages(merged_blob).size).to eq(8)
  end

  it "purges the input blobs after a successful merge" do
    blobs = [
      create_blob("smilie.png", "chat-1.png", "image/png"),
      create_blob("test.pdf", "chat-2.pdf", "application/pdf"),
    ]
    blobs.each { |blob| expect(blob).to receive(:purge) }

    described_class.perform(blobs:, max_size:)
  end

  it "recompresses image pages instead of dropping them when the merged PDF exceeds the budget" do
    blobs = [
      create_blob("cherry-blossom-1280x720.jpeg", "chat-1.jpeg", "image/jpeg"),
      create_blob("autumn-leaves-1280x720.jpeg", "chat-2.jpeg", "image/jpeg"),
    ]
    full_quality_size = described_class.perform(blobs:, max_size: 100.megabytes).byte_size
    # A budget one byte under the full-quality output, but above every raw input, forces
    # the retry ladder without tripping the per-file size check.
    budget = full_quality_size - 1
    expect(blobs.map(&:byte_size)).to all(be < budget)

    merged_blob = described_class.perform(blobs:, max_size: budget)

    expect(merged_blob.byte_size).to be <= budget
    expect(pages(merged_blob).size).to eq(2)
  end

  it "raises FilesTooLargeError when a single file exceeds the budget" do
    blobs = [create_blob("smilie.png", "chat.png", "image/png")]

    expect do
      described_class.perform(blobs:, max_size: 1_000)
    end.to raise_error(described_class::FilesTooLargeError, described_class::FILE_TOO_LARGE_MESSAGE)
  end

  it "raises FilesTooLargeError instead of truncating when the merged PDF cannot fit the budget" do
    # The PDF alone almost fills the budget and cannot be recompressed, so no image
    # compression step can make the pair fit.
    blobs = [
      create_blob("billion-dollar-company-chapter-0.pdf", "chapter.pdf", "application/pdf"), # 111_237 bytes
      create_blob("smilie.png", "screenshot.png", "image/png"),
    ]

    expect(blobs.first.byte_size).to be < 112_000
    expect do
      described_class.perform(blobs:, max_size: 112_000)
    end.to raise_error(described_class::FilesTooLargeError, described_class::FILES_TOO_LARGE_MESSAGE)
  end

  it "raises FilesTooLargeError when PDFs alone exceed the budget" do
    blobs = [
      create_blob("billion-dollar-company-chapter-0.pdf", "chapter.pdf", "application/pdf"),
      create_blob("test.pdf", "receipt.pdf", "application/pdf"),
    ]

    expect do
      described_class.perform(blobs:, max_size: 115_000)
    end.to raise_error(described_class::FilesTooLargeError, described_class::FILES_TOO_LARGE_MESSAGE)
  end

  it "raises MergeError for a PDF qpdf cannot process" do
    blobs = [
      create_blob("password_protected_pdf.pdf", "locked.pdf", "application/pdf"),
      create_blob("smilie.png", "screenshot.png", "image/png"),
    ]

    expect do
      described_class.perform(blobs:, max_size:)
    end.to raise_error(described_class::MergeError, described_class::UNPROCESSABLE_FILE_MESSAGE)
  end

  it "raises MergeError when more than MAX_CUSTOMER_COMMUNICATION_FILES files are provided" do
    stub_const("DisputeEvidence::MAX_CUSTOMER_COMMUNICATION_FILES", 2)
    blobs = [
      create_blob("smilie.png", "chat-1.png", "image/png"),
      create_blob("smilie.png", "chat-2.png", "image/png"),
      create_blob("smilie.png", "chat-3.png", "image/png"),
    ]

    expect do
      described_class.perform(blobs:, max_size:)
    end.to raise_error(described_class::MergeError, "You can attach up to 2 files.")
  end
end
