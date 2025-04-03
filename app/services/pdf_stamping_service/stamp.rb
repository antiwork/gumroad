# frozen_string_literal: true

module PdfStampingService::Stamp
  class Error < StandardError; end

  extend self

  def can_stamp_file?(product_file:)
    stamped_pdf_path = perform!(product_file:, watermark_text: "noop@gumroad.com")
    true # We don't actually do anything with the file, we just wanted to check that we could create it.
  rescue *PdfStampingService::ERRORS_TO_RESCUE => e
    Rails.logger.info("[#{name}.#{__method__}] Failed stamping #{product_file.id}: #{e.class} => #{e.message}")
    false
  ensure
    File.unlink(stamped_pdf_path) if File.exist?(stamped_pdf_path.to_s)
  end

  def perform!(product_file:, watermark_text:)
    product_file.download_original do |original_pdf|
      original_pdf_path = original_pdf.path
      original_pdf_path_shellescaped = Shellwords.shellescape(original_pdf_path)

      watermark_pdf_path = create_watermark_pdf!(original_pdf_path:, watermark_text:)
      watermark_pdf_path_shellescaped = Shellwords.shellescape(watermark_pdf_path)

      stamped_pdf_file_name = build_stamped_pdf_file_name(product_file)
      stamped_pdf_path = "#{Dir.tmpdir}/#{stamped_pdf_file_name}"
      stamped_pdf_path_shellescaped = Shellwords.shellescape(stamped_pdf_path)

      apply_watermark!(
        original_pdf_path_shellescaped,
        watermark_pdf_path_shellescaped,
        stamped_pdf_path_shellescaped
      )

      stamped_pdf_path
    ensure
      File.unlink(watermark_pdf_path) if File.exist?(watermark_pdf_path.to_s)
    end
  end

  private
    def build_stamped_pdf_file_name(product_file)
      extname = File.extname(product_file.s3_url)
      basename = File.basename(product_file.s3_url, extname)
      random_marker = SecureRandom.hex
      stamped_pdf_file_name = "#{basename}_#{random_marker}#{extname}"
      if stamped_pdf_file_name.bytesize > MAX_FILE_NAME_BYTESIZE
        truncated_basename_bytesize = MAX_FILE_NAME_BYTESIZE - extname.bytesize - random_marker.bytesize - 1 # 1 added underscore
        truncated_basename = basename.truncate_bytes(truncated_basename_bytesize, omission: nil)
        stamped_pdf_file_name = "#{truncated_basename}_#{random_marker}#{extname}"
      end
      stamped_pdf_file_name
    end

    def create_watermark_pdf!(original_pdf_path:, watermark_text:)
      # Get the dimensions of original pdf's first page
      reader = PDF::Reader.new(original_pdf_path)
      begin
        first_page = reader.page(1)
      rescue NoMethodError
        raise PDF::Reader::MalformedPDFError
      end
      media_box = first_page.attributes[:MediaBox]
      # Sometimes we see corrupt PDFs without the mandated MediaBox attribute which causes an error, so assume
      # that PDF is 8.5x11 portrait and place stamp at "bottom right". If PDF is landscape, it is a little centered.
      if media_box.is_a?(Array)
        width = media_box[2] - media_box[0]
        height = media_box[3] - media_box[1]
      else
        # width and height of 8.5x11 portrait page
        width = 612.0
        height = 792.0
      end

      # The origin is at the bottom-left
      watermark_x = width - 356
      watermark_y = 50

      watermark_pdf_path = "#{Dir.tmpdir}/watermark_#{SecureRandom.hex}_#{Digest::SHA1.hexdigest(watermark_text)}.pdf"
      pdf = Prawn::Document.new(page_size: [width, height], margin: 0)
      # TODO(s3ththompson): Remove subset: false once https://github.com/prawnpdf/prawn/issues/1361 is fixed
      pdf.font_families.update(
        "ABC Favorit" => {
          normal: { file: Rails.root.join("app", "assets", "fonts", "ABCFavorit", "ttf", "ABCFavorit-Regular.ttf"), subset: false },
          italic: { file: Rails.root.join("app", "assets", "fonts", "ABCFavorit", "ttf", "ABCFavorit-RegularItalic.ttf"), subset: false },
          bold: { file: Rails.root.join("app", "assets", "fonts", "ABCFavorit", "ttf", "ABCFavorit-Bold.ttf"), subset: false },
          bold_italic: { file: Rails.root.join("app", "assets", "fonts", "ABCFavorit", "ttf", "ABCFavorit-BoldItalic.ttf"), subset: false }
        }
      )

      pdf.fill_color "C1C1C1"
      pdf.font("ABC Favorit", style: :bold)
      pdf.text_box("Sold to", at: [watermark_x, watermark_y], width: 300, align: :right, size: 11, fallback_fonts: %w[Helvetica])

      pdf.fill_color "C1C1C1"
      pdf.font("ABC Favorit", style: :normal)
      pdf.text_box(watermark_text, at: [watermark_x, watermark_y - 14], width: 300, align: :right, size: 11, fallback_fonts: %w[Helvetica])

      pdf.image("#{Rails.root}/app/assets/images/pdf_stamp.png", at: [watermark_x + 305, watermark_y], width: 24)

      # pdftk stamps all pages by default, repeating the last page of the stamp until the end of the original pdf.

      pdf.render_file(watermark_pdf_path)
      watermark_pdf_path
    end

    def apply_watermark!(original_pdf_path_shellescaped, watermark_pdf_path_shellescaped, stamped_pdf_path_shellescaped)
      command = "pdftk #{original_pdf_path_shellescaped} multistamp #{watermark_pdf_path_shellescaped} output #{stamped_pdf_path_shellescaped}"
      stdout, stderr, status = Open3.capture3(command)
      return if status.success?

      Rails.logger.error("[#{name}.#{__method__}] Failed to execute command: #{command}")
      Rails.logger.error("[#{name}.#{__method__}] STDOUT: #{stdout}")
      Rails.logger.error("[#{name}.#{__method__}] STDERR: #{stderr}")
      error_message = parse_error_message(stdout, stderr)
      raise Error, "Error generating stamped PDF: #{error_message}"
    end

    def parse_error_message(stdout, stderr)
      if stderr.include?("unknown.encryption.type")
        "PDF is encrypted."
      else
        stderr.split("\n").first
      end
    end
end
