# frozen_string_literal: true

module WithFileProperties
  include InfosHelper

  MAX_DOWNLOAD_SIZE = 1_073_741_824 # 1gb
  MAX_VIDEO_DOWNLOAD_SIZE = 40.gigabytes

  def file_info(require_shipping = false)
    # One-off for not showing image properties for a physical product.
    return {} if filegroup == "image" && require_shipping

    attributes = {
      Size: size_displayable,
      Duration: duration_displayable(duration),
      Length: pagelength_displayable,
      Resolution: resolution_displayable
    }.delete_if { |_k, v| v.blank? }

    attributes
  end

  def determine_and_set_filegroup(extension)
    # CONVENTION: the filegroup is what follows the last underscore
    self.filetype = extension
    FILE_REGEX.each do |k, v|
      if extension.match(v)
        self.filegroup = k.split("_")[-1]
        break
      end
    end

    # Case filetype is unidentified
    self.filegroup = "url" if filegroup.nil?
  end

  def analyze
    return if deleted? || !s3?

    clear_properties
    confirm_s3_key!

    begin
      self.size = s3_object.content_length
    rescue Aws::S3::Errors::NotFound => e
      raise e.exception("Key = #{s3_key} -- #{self.class.name}.id = #{id}")
    end
    file_uuid = SecureRandom.uuid
    logger.info("Analyze -- writing #{s3_url} to #{file_uuid}")
    FILE_REGEX.each do |file_type, regex|
      next unless filetype.match(regex)

      if methods.grep(/assign_#{file_type}_attributes/) != [] && size && size < max_download_size_for_file_type(file_type)
        temp_file = Tempfile.new([file_uuid, File.extname(s3_url)], encoding: "ascii-8bit")
        begin
          s3_object.get(response_target: temp_file)
          temp_file.rewind
          path = temp_file.path
          if path.present?
            action = :"assign_#{file_type}_attributes"
            respond_to?(action) && send(action, path)
          end
        ensure
          temp_file.close!
        end
      end
      break
    end
    save!
  end

  def clear_properties
    self.duration = nil
    self.bitrate = nil
    self.framerate = nil
    self.width = nil
    self.height = nil
    self.pagelength = nil
  end

  def log_uncountable
    logger.info("Could not get pagecount for #{self.class} #{id}")
  end

  def assign_video_attributes(path)
    if filetype == "mov"
      probe = Ffprobe.new(path).parse
      self.framerate = probe.framerate
      self.duration = probe.duration.to_i
      self.width = probe.width
      self.height = probe.height
      self.bitrate = probe.bit_rate.to_i
    else
      movie = FFMPEG::Movie.new(path)
      self.framerate = movie.frame_rate
      self.duration  = movie.duration
      self.width = movie.width
      self.height = movie.height
      self.bitrate = movie.bitrate if movie.bitrate.present?
    end
    self.analyze_completed = true if respond_to?(:analyze_completed=)
    save!

    video_file_analysis_completed
  rescue NoMethodError
    logger.info("Could not analyze movie product file #{id}")
  end

  def assign_audio_attributes(path)
    song = FFMPEG::Movie.new(path)
    self.duration = song.duration
    self.bitrate = song.bitrate
  rescue ArgumentError
    logger.error("Cannot Analyze product file: #{id} of filetype: #{filetype}. FFMPEG cannot handle certain .wav files.")
  end

  def assign_image_attributes(path)
    image = ImageSorcery.new(path)
    self.width = image.dimensions[:x]
    self.height = image.dimensions[:y]
  end

  def assign_epub_document_attributes(path)
    epub_section_info = {}
    book = EPUB::Parser.parse(path)
    section_count = book.spine.items.count
    self.pagelength = section_count

    book.spine.items.each_with_index do |item, index|
      section_name = item.content_document.nokogiri.xpath("//xmlns:title").try(:text)
      section_number = index + 1 # Since the index is 0-based and section number is 1-based.
      section_id = item.id
      epub_section_info[section_id] = { "section_number" => section_number, "section_name" => section_name }
    end

    self.epub_section_info = epub_section_info
  rescue NoMethodError, Archive::Zip::EntryError, ArgumentError => e
    logger.info("Could not analyze epub product file #{id} (#{e.class}: #{e.message})")
  end

  def assign_document_attributes(path)
    count_pages(path)
  end

  def assign_psd_attributes(path)
    image = ImageSorcery.new(path)
    self.width = image.dimensions[:x]
    self.height = image.dimensions[:y]
  end

  def count_pages(path)
    counter = :"count_pages_#{ filetype }"
    if respond_to?(counter) # is there a counter method corresponding to this filetype?
      begin
        send(counter, path)
      rescue StandardError
        log_uncountable
      end
    else
      log_uncountable
    end
  end

  def count_pages_doc(path)
    self.pagelength = Subexec.run("wvSummary #{path}").output.scan(/Number of Pages = (\d+)/)[0][0]
  end

  def count_pages_docx(path)
    Zip::File.open(path) do |zipfile|
      self.pagelength = zipfile.file.read("docProps/app.xml").scan(%r{<Pages>(\d+)</Pages>})[0][0]
    end
  end

  def count_pages_pdf(path)
    self.pagelength = PDF::Reader.new(path).page_count
  end

  def count_pages_ppt(path)
    self.pagelength = Subexec.run("wvSummary #{path} | grep \"Number of Slides\"").output.scan(/Number of Slides = (\d+)/)[0][0]
  end

  def count_pages_pptx(path)
    Zip::File.open(path) do |zipfile|
      self.pagelength = zipfile.file.read("docProps/app.xml").scan(%r{<Slides>(\d+)</Slides>})[0][0]
    end
  end

  private
    def max_download_size_for_file_type(file_type)
      file_type == "video" ? MAX_VIDEO_DOWNLOAD_SIZE : MAX_DOWNLOAD_SIZE
    end

    def transcode_video(streamable)
      TranscodeVideoForStreamingWorker.perform_in(10.seconds, streamable.id, streamable.class.name)
    end

    def video_file_analysis_completed
    end
end
