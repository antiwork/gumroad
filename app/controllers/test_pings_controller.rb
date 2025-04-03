# frozen_string_literal: true

class TestPingsController < Sellers::BaseController
  def create
    authorize([:settings, :advanced, current_seller], :test_ping?)

    unless /\A#{URI::DEFAULT_PARSER.make_regexp}\z/.match?(params[:url])
      render json: { success: false, error_message: "That URL seems to be invalid." }
      return
    end

    message = if current_seller.send_test_ping params[:url]
      "Your last sale's data has been sent to your Ping URL."
    else
      "There are no sales on your account to test with. Please make a test purchase and try again."
    end
    render json: { success: true, message: }
  rescue *INTERNET_EXCEPTIONS
    render json: { success: false, error_message: "That URL seems to be invalid." }
  rescue Exception
    render json: { success: false, error_message: "Sorry, something went wrong. Please try again." }
  end
end
