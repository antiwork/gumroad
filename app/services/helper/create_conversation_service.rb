# frozen_string_literal: true

class Helper::CreateConversationService
  def initialize(email:, subject:, message:)
    @recipient_email = email
    @subject = subject
    @message = message
  end

  def call
    client.create_conversation(email: @recipient_email, subject: @subject, message: @message)
  end

  private
    def client
      @client ||= Helper::Client.new
    end
end


