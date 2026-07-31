# frozen_string_literal: true

# Merges the seller's customer-communication uploads (JPG/PNG/PDF, in the order they picked
# them) into a single PDF blob, because Stripe accepts exactly one file for this evidence
# field and the submission is one-shot. Page order is preserved: for a chat log, order is
# part of the evidence. If the merged result cannot fit the Stripe size budget even after
# recompressing image pages, this raises instead of dropping pages — a silently truncated
# packet is the exact failure this service exists to prevent.
class DisputeEvidence::MergeCustomerCommunicationFilesService
  class MergeError < StandardError; end
  class FilesTooLargeError < MergeError; end

  MERGED_FILENAME = "customer_communication.pdf"
  IMAGE_CONTENT_TYPES = %w[image/jpeg image/png].freeze
  QPDF_SUCCESS_EXIT_CODES = PdfStampingService::Stamp::QPDF_SUCCESS_EXIT_CODES
  # PDF pages are sized to the source image (1px = 1pt), capped at the PDF spec's maximum
  # page dimension so an oversized screenshot cannot produce an invalid document.
  MAX_PAGE_DIMENSION_POINTS = 14_400
  # Attempted in order until the merged PDF fits the size budget. Only image pages can be
  # recompressed; input PDFs are carried through verbatim.
  IMAGE_COMPRESSION_STEPS = [
    { quality: 80, max_dimension: nil },
    { quality: 60, max_dimension: 2_000 },
    { quality: 40, max_dimension: 1_200 },
  ].freeze

  FILE_TOO_LARGE_MESSAGE = "One of the uploaded files exceeds the maximum size allowed."
  FILES_TOO_LARGE_MESSAGE = "The combined size of the uploaded files exceeds the maximum allowed, even after compression. Please remove a file or upload smaller versions."
  UNPROCESSABLE_FILE_MESSAGE = "One of the uploaded files could not be processed. Please check that every PDF opens correctly and is not password-protected."

  def self.perform(blobs:, max_size:)
    new(blobs:, max_size:).perform
  end

  def initialize(blobs:, max_size:)
    @blobs = blobs
    @max_size = max_size
  end

  # Returns a new application/pdf ActiveStorage::Blob and purges the input blobs.
  def perform
    if blobs.size > DisputeEvidence::MAX_CUSTOMER_COMMUNICATION_FILES
      raise MergeError, "You can attach up to #{DisputeEvidence::MAX_CUSTOMER_COMMUNICATION_FILES} files."
    end
    raise FilesTooLargeError, FILE_TOO_LARGE_MESSAGE if blobs.any? { _1.byte_size > max_size }

    downloaded_files = download_blobs
    merged_path = merge_within_size_budget(downloaded_files)

    merged_blob = File.open(merged_path) do |file|
      ActiveStorage::Blob.create_and_upload!(io: file, filename: MERGED_FILENAME, content_type: "application/pdf")
    end
    blobs.each(&:purge)
    merged_blob
  ensure
    downloaded_files&.each { _1[:tempfile].close! }
    File.unlink(merged_path) if merged_path && File.exist?(merged_path)
  end

  private
    attr_reader :blobs, :max_size

    def download_blobs
      blobs.map do |blob|
        tempfile = Tempfile.new(["dispute_evidence_input", File.extname(blob.filename.to_s)], binmode: true)
        blob.download { |chunk| tempfile.write(chunk) }
        tempfile.flush
        { tempfile:, content_type: blob.content_type }
      end
    end

    def merge_within_size_budget(downloaded_files)
      compressible = downloaded_files.any? { _1[:content_type].in?(IMAGE_CONTENT_TYPES) }
      compression_steps = compressible ? IMAGE_COMPRESSION_STEPS : IMAGE_COMPRESSION_STEPS.take(1)

      compression_steps.each do |compression|
        merged_path = merge(downloaded_files, compression)
        return merged_path if File.size(merged_path) <= max_size

        File.unlink(merged_path)
      end

      raise FilesTooLargeError, FILES_TOO_LARGE_MESSAGE
    end

    def merge(downloaded_files, compression)
      page_paths = []
      downloaded_files.each do |downloaded_file|
        if downloaded_file[:content_type].in?(IMAGE_CONTENT_TYPES)
          page_paths << image_to_pdf_page(downloaded_file[:tempfile].path, compression)
        else
          page_paths << downloaded_file[:tempfile].path
        end
      end

      merged_path = "#{Dir.tmpdir}/dispute_evidence_merged_#{SecureRandom.hex}.pdf"
      _stdout, stderr, status = Open3.capture3("qpdf", "--empty", "--pages", *page_paths, "--", merged_path)
      unless QPDF_SUCCESS_EXIT_CODES.include?(status.exitstatus)
        Rails.logger.error("[#{self.class.name}] qpdf failed: #{stderr}")
        File.unlink(merged_path) if File.exist?(merged_path)
        raise MergeError, UNPROCESSABLE_FILE_MESSAGE
      end

      merged_path
    ensure
      (page_paths - downloaded_files.map { _1[:tempfile].path }).each do |generated_path|
        File.unlink(generated_path) if File.exist?(generated_path)
      end
    end

    # Recompressing through JPEG also sidesteps the PNG variants (16-bit depth, interlaced)
    # that both Stripe and Prawn reject — see
    # Purchases::DisputeEvidenceController#covert_and_optimize_blob_if_needed.
    def image_to_pdf_page(image_path, compression)
      image = MiniMagick::Image.open(image_path)
      image.auto_orient
      image.resize("#{compression[:max_dimension]}x#{compression[:max_dimension]}>") if compression[:max_dimension]
      image.format("jpg")
      image.quality(compression[:quality]).colorspace("sRGB").strip

      width = [image.width, MAX_PAGE_DIMENSION_POINTS].min
      height = [image.height, MAX_PAGE_DIMENSION_POINTS].min

      page_path = "#{Dir.tmpdir}/dispute_evidence_page_#{SecureRandom.hex}.pdf"
      document = Prawn::Document.new(page_size: [width, height], margin: 0)
      document.image(image.path, fit: [width, height], position: :center, vposition: :center)
      document.render_file(page_path)
      page_path
    rescue MiniMagick::Error, MiniMagick::Invalid, Prawn::Errors::UnsupportedImageType => e
      Rails.logger.error("[#{self.class.name}] image conversion failed: #{e.class} => #{e.message}")
      raise MergeError, UNPROCESSABLE_FILE_MESSAGE
    end
end
