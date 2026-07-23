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

  def create
    # Honeypot: the form renders an invisible "website" field that humans never
    # fill in. Bots that do fill it get a fake success so they can't tell the
    # submission was dropped.
    return render json: { success: true } if params[:website].present?

    email = params[:email].to_s.strip
    category = params[:category].to_s
    message = params[:message].to_s.strip

    error = validation_error(email:, category:, message:)
    return render json: { success: false, error: }, status: :unprocessable_entity if error

    SupportContactMailer.contact_form(
      email:,
      category:,
      message:,
      user_id: logged_in_user&.id,
      referrer_path: safe_referrer_path
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
end
