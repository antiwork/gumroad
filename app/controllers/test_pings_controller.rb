# frozen_string_literal: true

class TestPingsController < Sellers::BaseController
  def create
    authorize([:settings, :advanced, current_seller], :test_ping?)

    unless /\A#{URI::DEFAULT_PARSER.make_regexp}\z/.match?(params[:url])
      render json: { success: false, error_message: "That URL seems to be invalid." }
      return
    end

    response = current_seller.send_test_ping params[:url]

    # send_test_ping returns the :no_sales sentinel (never nil) when there's nothing
    # to ping with. Do NOT test the response with nil?/truthiness: HTTParty::Response
    # overrides #nil? to return true for empty-bodied responses, which would misroute
    # a real 200-or-403-with-empty-body here.
    if response == :no_sales
      render json: { success: true, message: "There are no sales on your account to test with. Please make a test purchase and try again." }
    elsif response.success?
      render json: { success: true, message: "Your last sale's data has been sent to your Ping URL. Your endpoint responded with HTTP #{response.code}." }
    else
      # The ping was delivered but the endpoint rejected it (4xx/5xx). Surface the
      # status code so sellers can self-diagnose (e.g. a firewall or Cloudflare rule
      # returning 403) instead of concluding Gumroad never sent anything.
      render json: { success: false, error_message: "Your endpoint responded with HTTP #{response.code} instead of a success code. Check your endpoint's logs and any firewall or bot-protection rules (e.g. Cloudflare) that may be blocking Gumroad's requests." }
    end
  rescue *INTERNET_EXCEPTIONS
    # Connection-level failure: DNS, refused connection, timeout, SSL, etc.
    # The request never completed, so there is no HTTP status to report.
    render json: { success: false, error_message: "We couldn't reach your Ping URL — the connection failed or timed out. Check that the URL is correct and that your server is reachable from the internet." }
  rescue Exception
    render json: { success: false, error_message: "Sorry, something went wrong. Please try again." }
  end
end
