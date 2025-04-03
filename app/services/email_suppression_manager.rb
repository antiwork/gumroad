# frozen_string_literal: true

class EmailSuppressionManager
  SUPPRESSION_LISTS = [:bounces, :spam_reports]
  private_constant :SUPPRESSION_LISTS

  def initialize(email)
    @email = email
  end

  def reasons_for_suppression
    # Scan all subusers for the email and note the reasons for suppressions
    sendgrid_subusers.inject({}) do |reasons, (subuser, api_key)|
      supression_reasons = email_suppression_reasons(api_key)
      reasons[subuser] = supression_reasons if supression_reasons.present?
      reasons
    end
  end

  def unblock_email
    # Scan all subusers for the email and delete it from each suppression list
    # Return true if the email is unblocked from any of the lists
    sendgrid_subusers.inject(false) do |unblocked, (_, api_key)|
      unblocked | unblock_suppressed_email(api_key)
    end
  end

    private
      attr_reader :email

      def sendgrid(api_key)
        SendGrid::API.new(api_key:)
      end

      def email_suppression_reasons(api_key)
        suppression = sendgrid(api_key).client.suppression

        SUPPRESSION_LISTS.inject([]) do |reasons, list|
          parsed_body = suppression.public_send(list)._(email).get.parsed_body

          begin
            reasons << { list:, reason:  parsed_body.first[:reason] } if parsed_body.present?
          rescue => e
            Bugsnag.notify(e)
            Rails.logger.info "[EmailSuppressionManager] Error parsing SendGrid response: #{parsed_body}"
          end

          reasons
        end
      end

      def unblock_suppressed_email(api_key)
        suppression = sendgrid(api_key).client.suppression

        # Scan all lists for the email and delete it from each list
        # Return true if the email is found in any of the lists
        SUPPRESSION_LISTS.inject(false) do |unblocked, list|
          unblocked | successful_response?(suppression.public_send(list)._(email).delete.status_code)
        end
      end

      def successful_response?(status_code)
        (200..299).include?(status_code.to_i)
      end

      def sendgrid_subusers
        {
          gumroad: GlobalConfig.get("SENDGRID_GUMROAD_TRANSACTIONS_API_KEY"),
          followers: GlobalConfig.get("SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_API_KEY"),
          creators: GlobalConfig.get("SENDGRID_GR_CREATORS_API_KEY"),
          customers_level_1: GlobalConfig.get("SENDGRID_GR_CUSTOMERS_API_KEY"),
          customers_level_2: GlobalConfig.get("SENDGRID_GR_CUSTOMERS_LEVEL_2_API_KEY")
        }
      end
end
