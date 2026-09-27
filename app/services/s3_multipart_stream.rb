# frozen_string_literal: true

# Append-only S3 multipart upload: `write` fills one part at a time and hands each full part to at
# most `concurrency` upload threads, so memory stays near (concurrency + 1) * part_size whatever the
# object or write size. Nothing is visible at the key until #complete!.
#
# Aws::S3::Object#upload_stream was the obvious fit, but it hides the upload id and only aborts on
# StandardError, so a Sidekiq::Shutdown mid-build would leave the parts stored.
class S3MultipartStream
  class SizeMismatchError < StandardError; end
  # Raised in place of a part's own error, which stays as #cause, so a caller streaming from
  # another S3 request cannot mistake an upload failure for its own dropped connection.
  class PartUploadError < StandardError; end

  MIN_PART_SIZE = 5.megabytes
  MAX_PARTS = 10_000

  attr_reader :bytes_written, :parts_uploaded, :max_parts_in_flight

  # A SIGKILLed or OOM-killed build never reaches #abort!, and its parts stay stored until the
  # bucket expires them. The next build of the same key clears them; callers must hold that key.
  def self.abort_unfinished(s3_object)
    client = s3_object.client
    uploads = client.list_multipart_uploads(bucket: s3_object.bucket_name, prefix: s3_object.key).uploads
    uploads.select { _1.key == s3_object.key }.each do |upload|
      client.abort_multipart_upload(bucket: s3_object.bucket_name, key: s3_object.key, upload_id: upload.upload_id)
    end.size
  end

  def initialize(s3_object, part_size:, concurrency:, **create_options)
    raise ArgumentError, "part_size must be at least #{MIN_PART_SIZE}" if part_size < MIN_PART_SIZE

    @s3_object = s3_object
    @client = s3_object.client
    @part_size = part_size
    @concurrency = concurrency
    @create_options = create_options
    @buffer = new_buffer
    @in_flight = []
    @parts = []
    @parts_lock = Mutex.new
    @part_number = 0
    @bytes_written = 0
    @parts_uploaded = 0
    @max_parts_in_flight = 0
  end

  def write(bytes)
    start_upload unless @upload_id
    offset = 0
    while offset < bytes.bytesize
      length = [@part_size - @buffer.bytesize, bytes.bytesize - offset].min
      @buffer << (length == bytes.bytesize ? bytes : bytes.byteslice(offset, length))
      offset += length
      upload_buffer if @buffer.bytesize == @part_size
    end
    @bytes_written += bytes.bytesize
  end

  def complete!(expected_size:)
    start_upload unless @upload_id
    upload_buffer if @buffer.bytesize.positive? || @part_number.zero?
    @in_flight.each { join_part(_1) }
    @in_flight.clear
    raise SizeMismatchError, "wrote #{@bytes_written} bytes, expected #{expected_size}" if @bytes_written != expected_size

    parts = @parts.sort_by { _1[:part_number] }
    @client.complete_multipart_upload(**object_params, upload_id: @upload_id, multipart_upload: { parts: })
    @completed = true
    stored_size = @client.head_object(**object_params).content_length
    raise SizeMismatchError, "stored #{stored_size} bytes, expected #{expected_size}" if stored_size != expected_size
  end

  # Safe to call from an ensure on any exit: waits for parts still in flight so none lands after
  # the abort, then drops the upload. A completed upload is left alone.
  def abort!
    return if @upload_id.nil? || @completed

    @in_flight.each { |thread| thread.join rescue nil }
    @in_flight.clear
    @buffer = new_buffer
    @client.abort_multipart_upload(**object_params, upload_id: @upload_id)
    @upload_id = nil
  end

  private
    def object_params
      { bucket: @s3_object.bucket_name, key: @s3_object.key }
    end

    def start_upload
      @upload_id = @client.create_multipart_upload(**object_params, **@create_options).upload_id
    end

    def new_buffer
      String.new(capacity: @part_size, encoding: Encoding::BINARY)
    end

    def upload_buffer
      @part_number += 1
      raise ArgumentError, "object needs more than #{MAX_PARTS} parts of #{@part_size} bytes" if @part_number > MAX_PARTS

      # A failed part surfaces here, which stops the build at its next write.
      finished, @in_flight = @in_flight.partition { !_1.alive? }
      finished.each { join_part(_1) }
      join_part(@in_flight.shift) while @in_flight.size >= @concurrency
      body = @buffer
      @buffer = new_buffer
      thread = Thread.new(body, @part_number) { |part_body, number| upload_part(part_body, number) }
      thread.report_on_exception = false
      @in_flight << thread
      @max_parts_in_flight = [@max_parts_in_flight, @in_flight.size].max
    end

    def join_part(thread)
      thread.value
    rescue StandardError => e
      raise PartUploadError, "part upload failed: #{e.class}: #{e.message}"
    end

    def upload_part(body, part_number)
      content_md5 = Digest::MD5.base64digest(body)
      response = @client.upload_part(**object_params, upload_id: @upload_id, part_number:, body:, content_md5:)
      @parts_lock.synchronize do
        @parts << { part_number:, etag: response.etag }
        @parts_uploaded += 1
      end
    ensure
      body.clear
    end
end
