# frozen_string_literal: true

module MultipartTransfer
  # Public: Transfer an item from some arbitrary url source to our s3 bucket using multipart transfer
  #
  # source_file_url  - The url of the file you wish to copy
  # destination_filename - Optional, the destination filename of the file you want to copy over, used in renaming
  # existing_s3_object - Optional, the existing s3 object in our system you are looking to copy over. Providing this
  # object allows us to use AWS's multipart transfer implementation.
  #
  def self.transfer_to_s3(source_file_url, destination_filename: nil, existing_s3_object: nil)
    s3_guid = (SecureRandom.uuid.split("")[1..-1] - ["-"]).join + SecureRandom.random_number(10).to_s
    uri = URI(source_file_url)
    if destination_filename.present?
      file_name = destination_filename
    else
      file_name = uri.path
      file_name = file_name[1..-1] if file_name.start_with?("/")
    end
    destination_key = "attachments/#{s3_guid}/original/#{file_name}"
    if existing_s3_object.present?
      Aws::S3::Resource.new.bucket(S3_BUCKET).object(destination_key).copy_from(existing_s3_object,
                                                                                multipart_copy: (existing_s3_object.content_length > 5.megabytes),
                                                                                content_type: existing_s3_object.content_type)
    else
      transfer_non_s3_file_to_s3(destination_key, s3_guid, uri)
    end
    destination_key
  end

  def self.transfer_non_s3_file_to_s3(destination_key, s3_guid, uri)
    http_req = Net::HTTP.new(uri.host, uri.port)
    http_req.use_ssl = uri.scheme == "https"
    http_req.start do |http|
      request = Net::HTTP::Get.new uri
      http.request request do |response|
        extname = File.extname(uri.path)
        temp_file = Tempfile.new([s3_guid, extname], encoding: "ascii-8bit")
        response.read_body do |chunk|
          temp_file.write(chunk)
        end
        Aws::S3::Resource.new.bucket(S3_BUCKET).object(destination_key).upload_file(temp_file.path,
                                                                                    content_type: fetch_content_type(uri))
        temp_file.close(true)
      end
    end
  end

  def self.fetch_content_type(uri)
    HTTParty.head(uri).headers["content-type"]
  end
  private_class_method :fetch_content_type
end
