# frozen_string_literal: true

require "open3"
require "shellwords"

module WithFileProperties
  include InfosHelper

  MAX_DOWNLOAD_SIZE = 40.gigabytes

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

      if methods.grep(/assign_#{file_type}_attributes/) != [] && size && size < MAX_DOWNLOAD_SIZE
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
    # Only the probing itself is guarded. A NoMethodError raised later — e.g. by
    # a nil association while queueing the transcode — must not be reported to
    # the seller as a broken video, because by then the file has analyzed fine.
    begin
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
    rescue NoMethodError
      # The .mov path reads the first video stream unguarded, so a file with no
      # video stream raises here instead of returning nils.
      return video_analysis_failed("probe output was missing expected fields")
    end

    # ffprobe can also "succeed" without finding a video stream — a truncated or
    # corrupt upload yields nil width/height (and duration 0) instead of an
    # exception. Treat that as a failed analysis: streaming needs the height to
    # pick an HLS preset, so a file without dimensions can never be transcoded
    # (see Streamable#transcodable?). Marking it analyzed anyway used to leave
    # the file permanently unplayable with nothing to retry and no signal to the
    # seller (gumroad-private#1332).
    return video_analysis_failed("no video stream found (nil width/height)") if width.blank? || height.blank?

    self.analyze_completed = true if respond_to?(:analyze_completed=)
    save!

    video_file_analysis_completed
  end

  def assign_audio_attributes(path)
    song = FFMPEG::Movie.new(path)
    self.duration = song.duration
    self.bitrate = song.bitrate
  rescue ArgumentError
    logger.error("Cannot Analyze product file: #{id} of filetype: #{filetype}. FFMPEG cannot handle certain .wav files.")
  end

  def assign_image_attributes(path)
    image = MiniMagick::Image.open(path)
    self.width = image.width
    self.height = image.height
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
    image = MiniMagick::Image.open(path)
    self.width = image.width
    self.height = image.height
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
    stdout, _stderr, _status = Open3.capture3("wvSummary", path)
    self.pagelength = stdout.scan(/Number of Pages = (\d+)/)[0][0]
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
    stdout, _stderr, _status = Open3.capture3("bash", "-c", "wvSummary #{Shellwords.escape(path)} | grep \"Number of Slides\"")
    self.pagelength = stdout.scan(/Number of Slides = (\d+)/)[0][0]
  end

  def count_pages_pptx(path)
    Zip::File.open(path) do |zipfile|
      self.pagelength = zipfile.file.read("docProps/app.xml").scan(%r{<Slides>(\d+)</Slides>})[0][0]
    end
  end

  private
    def transcode_video(streamable)
      TranscodeVideoForStreamingWorker.perform_in(10.seconds, streamable.id, streamable.class.name)
    end

    # A video we could not read metadata from. Clears analyze_completed so a
    # later re-analyze can still succeed if the source is replaced (a file that
    # analyzed fine before and is re-analyzed after its source was replaced by a
    # corrupt one must not keep the flag), and tells the seller their file is
    # unusable rather than failing silently.
    def video_analysis_failed(reason)
      logger.info("Could not analyze movie #{self.class.name} #{id}: #{reason}")
      self.analyze_completed = false if respond_to?(:analyze_completed=)
      save! if changed?
      transcoding_failed if respond_to?(:transcoding_failed)
      nil
    end

    def video_file_analysis_completed
    end
end
