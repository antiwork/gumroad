# frozen_string_literal: true

# Given a file:
# - Check if file size is acceptable for direct attachment
# - Yes: Return file
# - No: Return temporary expiring S3 link
class MailerAttachmentOrLinkService
  # https://sendgrid.com/docs/ui/sending-email/attachments-with-digioh/
  # Can send upto 30 MB, but recommended is 10.
  MAX_FILE_SIZE = 10.megabytes
  attr_reader :file, :filename, :extension

  def initialize(file:, filename: nil, extension: nil)
    @file = file
    @filename = filename
    @extension = extension
  end

  def perform
    if file.size <= MAX_FILE_SIZE
      { file:, url: nil }
    else
      #  Ensure start of file before read
      file.rewind
      { file: nil, url: ExpiringS3FileService.new(file:,
                                                  extension:,
                                                  filename: @filename).perform }
    end
  end
end
