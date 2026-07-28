# frozen_string_literal: true

module PdfStampingService::Stamp
  class Error < StandardError; end

  extend self

  QPDF_ENCRYPTED_EXIT_CODE = 0
  QPDF_SUCCESS_EXIT_CODES = [0, 3].freeze

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
      decrypted_pdf_path = decrypt_pdf(original_pdf.path)
      original_pdf_path = decrypted_pdf_path || original_pdf.path
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
      File.unlink(decrypted_pdf_path) if decrypted_pdf_path && File.exist?(decrypted_pdf_path)
      # If stamping raised, qpdf may still have written a partial output file. Nothing will ever read
      # it (perform! only returns the path on success), so clean it up instead of leaving it in tmp.
      File.unlink(stamped_pdf_path) if $! && stamped_pdf_path && File.exist?(stamped_pdf_path.to_s)
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
          normal: { file: Rails.root.join("public", "fonts", "ABCFavorit", "ttf", "ABCFavorit-Regular.ttf"), subset: false },
          italic: { file: Rails.root.join("public", "fonts", "ABCFavorit", "ttf", "ABCFavorit-RegularItalic.ttf"), subset: false },
          bold: { file: Rails.root.join("public", "fonts", "ABCFavorit", "ttf", "ABCFavorit-Bold.ttf"), subset: false },
          bold_italic: { file: Rails.root.join("public", "fonts", "ABCFavorit", "ttf", "ABCFavorit-BoldItalic.ttf"), subset: false }
        }
      )

      pdf.fill_color "C1C1C1"
      pdf.font("ABC Favorit", style: :bold)
      pdf.text_box("Sold to", at: [watermark_x, watermark_y], width: 300, align: :right, size: 11, fallback_fonts: %w[Helvetica])

      pdf.fill_color "C1C1C1"
      pdf.font("ABC Favorit", style: :normal)
      pdf.text_box(watermark_text, at: [watermark_x, watermark_y - 14], width: 300, align: :right, size: 11, fallback_fonts: %w[Helvetica])

      pdf.image("#{Rails.root}/public/images/pdf_stamp.png", at: [watermark_x + 305, watermark_y], width: 24)

      pdf.render_file(watermark_pdf_path)
      watermark_pdf_path
    end

    # Overlays the single-page watermark onto page 1 of the document, leaving every other page and
    # the document's structure alone.
    #
    # We use `qpdf --overlay --to=1` rather than pdftk here. Stamping used to extract page 1 with
    # `pdftk cat 1`, stamp it, extract pages 2-end, then concatenate the pieces back together. That
    # rebuild silently threw away the document outline (the heading bookmarks readers use to
    # navigate a long book) and the Title/Author metadata, because pdftk's `cat` does not carry
    # those structures across. A creator reported their technical book arriving with its whole
    # navigation tree missing, which left them choosing between stamped copies and a usable book.
    #
    # qpdf edits the existing document in place instead of rebuilding it from pieces, so the
    # outline, metadata, per-page sizes and rotation all survive, and `--to=1` restricts the visible
    # stamp to the first page (matching the behaviour #4206 introduced for performance).
    def apply_watermark!(original_pdf_path_shellescaped, watermark_pdf_path_shellescaped, stamped_pdf_path_shellescaped)
      run_stamping_command!("qpdf #{original_pdf_path_shellescaped} --overlay #{watermark_pdf_path_shellescaped} --to=1 -- #{stamped_pdf_path_shellescaped}")
    end

    def run_stamping_command!(command)
      stdout, stderr, status = Open3.capture3(command)
      # qpdf exits 3 when it recovered from problems in the source PDF (a damaged xref table, say)
      # but still wrote valid output, so treat that as success like the decrypt step already does.
      return if QPDF_SUCCESS_EXIT_CODES.include?(status.exitstatus)

      Rails.logger.error("[#{name}.apply_watermark!] Failed to execute command: #{command}")
      Rails.logger.error("[#{name}.apply_watermark!] STDOUT: #{stdout}")
      Rails.logger.error("[#{name}.apply_watermark!] STDERR: #{stderr}")
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

    def decrypt_pdf(original_pdf_path)
      return unless pdf_encrypted?(original_pdf_path)

      decrypted_pdf_path = "#{Dir.tmpdir}/decrypted_#{SecureRandom.hex}.pdf"
      _stdout, _stderr, status = Open3.capture3("qpdf", "--decrypt", "--password=", original_pdf_path, decrypted_pdf_path)
      return decrypted_pdf_path if QPDF_SUCCESS_EXIT_CODES.include?(status.exitstatus)

      File.unlink(decrypted_pdf_path) if File.exist?(decrypted_pdf_path)
      nil
    end

    def pdf_encrypted?(original_pdf_path)
      _stdout, _stderr, status = Open3.capture3("qpdf", "--is-encrypted", original_pdf_path)
      status.exitstatus == QPDF_ENCRYPTED_EXIT_CODE
    end
end
