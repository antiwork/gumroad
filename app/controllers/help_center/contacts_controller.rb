# frozen_string_literal: true

# Receives Help Center contact form submissions and forwards them into the
# support pipeline. Today the transport is email to support@gumroad.com (the
# inbox Helper ingests) via SupportContactMailer, enqueued through ActiveJob so
# a slow SMTP call never blocks the request.
#
# Upgrade path: when a server-side Helper API client exists (Helper is
# currently integrated only at the OAuth level — see
# db/seeds/030_development/helper_oauth_application.rb), replace the mailer
# call with a direct "create conversation" API call so submissions land in
# Helper with structured metadata instead of parsed email.
class HelpCenter::ContactsController < HelpCenter::BaseController
  CATEGORIES = ["account", "payouts", "purchases & refunds", "technical issue", "other"].freeze
  MIN_MESSAGE_LENGTH = 10
  MAX_MESSAGE_LENGTH = 10_000
  # Images ride along on the outgoing email instead of being stored, so these
  # caps keep one submission inside a single message the support inbox accepts.
  MAX_ATTACHMENTS = 3
  MAX_ATTACHMENT_BYTES = 3.megabytes
  MAX_TOTAL_ATTACHMENT_BYTES = 6.megabytes

  def create
    # Honeypot: the form renders an invisible "website" field that humans never
    # fill in. Bots that do fill it get a fake success so they can't tell the
    # submission was dropped.
    return render json: { success: true } if params[:website].present?

    email = params[:email].to_s.strip
    category = params[:category].to_s
    message = params[:message].to_s.strip

    attachments, attachment_error = read_attachments
    error = validation_error(email:, category:, message:) || attachment_error
    return render json: { success: false, error: }, status: :unprocessable_entity if error

    SupportContactMailer.contact_form(
      email:,
      category:,
      message:,
      user_id: logged_in_user&.id,
      referrer_path: safe_referrer_path,
      attachments:
    ).deliver_later

    render json: { success: true }
  end

  private
    def validation_error(email:, category:, message:)
      return "Please enter a valid email address." unless EmailFormatValidator.valid?(email)
      return "Please select a category." unless CATEGORIES.include?(category)
      return "Please tell us a bit more so we can help (at least #{MIN_MESSAGE_LENGTH} characters)." if message.length < MIN_MESSAGE_LENGTH
      return "Your message is too long. Please shorten it or email support@gumroad.com directly." if message.length > MAX_MESSAGE_LENGTH

      nil
    end

    # The page the user came from helps support triage, but it's user-supplied
    # data — only forward a same-app path, never an arbitrary URL.
    def safe_referrer_path
      referrer = params[:referrer_path].to_s
      referrer if referrer.start_with?("/") && !referrer.start_with?("//")
    end

    # Multipart image uploads arrive as `attachments[]`; Rails hands indexed
    # params over as a Hash. The bytes are inlined into the email rather than
    # stored: a submission has no owned record to hang a file on, and support
    # reads the images out of the message anyway.
    def read_attachments
      raw = params[:attachments]
      uploads = (raw.respond_to?(:values) ? raw.values : Array(raw)).grep(ActionDispatch::Http::UploadedFile)
      return [[], nil] if uploads.empty?
      return [[], "Please attach at most #{MAX_ATTACHMENTS} images."] if uploads.size > MAX_ATTACHMENTS
      # Reject on the size of the spooled upload before reading any of it: read
      # first would pull the whole body into memory only to reject it.
      return [[], "Each image must be smaller than #{MAX_ATTACHMENT_BYTES / 1.megabyte} MB."] if uploads.any? { |upload| upload.size > MAX_ATTACHMENT_BYTES }
      return [[], "Attachments must total less than #{MAX_TOTAL_ATTACHMENT_BYTES / 1.megabyte} MB."] if uploads.sum(&:size) > MAX_TOTAL_ATTACHMENT_BYTES

      files = []
      uploads.each do |upload|
        content = upload.read
        mime_type = image_mime_type(content)
        return [[], "Attachments must be PNG, JPG, GIF or WEBP images."] if mime_type.nil?

        files << { filename: upload.original_filename.to_s, mime_type:, content: }
      end

      # Sidekiq serializes job arguments as JSON, which cannot carry raw binary —
      # base64 keeps the bytes intact through the queue and the mailer decodes them.
      [files.map { |file| file.merge(content: Base64.strict_encode64(file[:content])) }, nil]
    end

    # The browser-declared content type and filename are both user input, so
    # only the leading bytes decide what we forward.
    def image_mime_type(content)
      return "image/png" if content.start_with?("\x89PNG\r\n\x1A\n".b)
      return "image/jpeg" if content.start_with?("\xFF\xD8\xFF".b)
      return "image/gif" if content.start_with?("GIF87a".b, "GIF89a".b)
      return "image/webp" if content.byteslice(0, 4) == "RIFF" && content.byteslice(8, 4) == "WEBP"

      nil
    end
end
