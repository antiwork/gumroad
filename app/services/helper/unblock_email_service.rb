# frozen_string_literal: true

class Helper::UnblockEmailService
  include ActionView::Helpers::TextHelper

  attr_accessor :recent_blocked_purchase

  def initialize(conversation_id:, email_id:, email:)
    @conversation_id = conversation_id
    @email_id = email_id
    @email = email
    @recent_blocked_purchase = nil
  end

  def process
    return if Feature.inactive?(:helper_unblock_emails)

    @replied = unblock_email_blocked_by_gumroad
    @replied |= unblock_email_suppressed_by_sendgrid
    @replied |= process_email_blocked_by_creator
  end

  def replied? = @replied.present?

  private
    attr_reader :email, :conversation_id

    REPLIES = {
      blocked_by_gumroad: <<~REPLY,
      Hey there,

      Happy to help today! We noticed your purchase attempts failed as they were flagged as potentially fraudulent. Don’t worry, our system can occasionally throw a false alarm.

      We have removed these blocks, so could you please try making the purchase again? In case it still fails, we recommend trying with a different browser and/or a different internet connection.

      If those attempts still don't work, feel free to write back to us and we will investigate further.

      Thanks!
      REPLY
      suppressed_by_sendgrid: <<~REPLY,
      Hey,

      Sorry about that! It seems our email provider stopped sending you emails after a few of them bounced.

      I’ve fixed this and you should now start receiving emails as usual. Please let us know if you don't and we'll take a closer look!

      Also, please add our email to your contacts list and ensure that you haven't accidentally marked any emails from us as spam.

      Hope this helps!
      REPLY
      blocked_by_creator: <<~REPLY,
      Hey there,

      It looks like a creator has blocked you from purchasing their products. Please reach out to them directly to resolve this.

      Feel free to write back to us if you have any questions.

      Thanks!
      REPLY
    }.freeze
    private_constant :REPLIES

    def helper
      @helper ||= Helper::Client.new
    end

    def unblock_email_blocked_by_gumroad
      if recent_blocked_purchase.present?
        unblock_buyer!(purchase: recent_blocked_purchase)
      else
        blocked_email = BlockedObject.email.find_active_object(email)
        return unless blocked_email.present?

        blocked_email.unblock!
      end

      send_reply(REPLIES[:blocked_by_gumroad])
    end

    def unblock_email_suppressed_by_sendgrid
      email_suppression_manager = EmailSuppressionManager.new(email)

      reasons = format_reasons(email_suppression_manager.reasons_for_suppression)
      add_note_to_conversation(reasons) if reasons.present?

      unblocked = email_suppression_manager.unblock_email
      send_reply(REPLIES[:suppressed_by_sendgrid]) if unblocked && !replied?
    end

    def process_email_blocked_by_creator
      blocked_email = BlockedCustomerObject.email.where(object_value: email).present?
      return unless blocked_email.present?

      send_reply(REPLIES[:blocked_by_creator], draft: true) unless replied?
    end

    def add_note_to_conversation(message)
      helper.add_note(conversation_id:, message:)
    end

    def send_reply(reply, draft: false)
      Rails.logger.info "[Helper::UnblockEmailService] Replied to conversation #{@conversation_id}"

      formatted_reply = simple_format(reply)
      if Feature.active?(:auto_reply_for_blocked_emails_in_helper) && !draft
        helper.send_reply(conversation_id:, message: formatted_reply)
        helper.close_conversation(conversation_id:)
      else
        helper.send_reply(conversation_id:, message: formatted_reply, draft: true, response_to: @email_id)
      end
    end

    def unblock_buyer!(purchase:)
      purchase.unblock_buyer!

      comment_content = "Buyer unblocked by Helper webhook"
      purchase.comments.create!(content: comment_content, comment_type: "note", author_id: GUMROAD_ADMIN_ID)
      if purchase.purchaser.present?
        purchase.purchaser.comments.create!(content: comment_content,
                                            comment_type: "note",
                                            author_id: GUMROAD_ADMIN_ID,
                                            purchase:)
      end
    end

    def bullet_list(lines)
      lines.map { |line| "• #{line}" }.join("\n")
    end

    def format_reasons(reasons)
      formatted_reasons = reasons.flat_map do |sendgrid_subuser, suppressions|
        suppressions.flat_map do |supression|
          "The email #{email} was suppressed in SendGrid. Subuser: #{sendgrid_subuser}, List: #{supression[:list]}, Reason: #{supression[:reason]}"
        end
      end

      bullet_list(formatted_reasons)
    end
end
