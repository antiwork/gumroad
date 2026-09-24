# frozen_string_literal: true

class EmailSuppressionManager
  ALL_SUPPRESSION_LISTS = [:bounces, :blocks, :spam_reports, :invalid_emails].freeze

  # All SendGrid subusers we send through. Suppression lists are per-subuser, so anything
  # scanning or clearing suppressions must check every one of these.
  def self.subuser_api_keys
    {
      gumroad: GlobalConfig.get("SENDGRID_GUMROAD_TRANSACTIONS_API_KEY"),
      followers: GlobalConfig.get("SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_API_KEY"),
      creators: GlobalConfig.get("SENDGRID_GR_CREATORS_API_KEY"),
      customers_level_1: GlobalConfig.get("SENDGRID_GR_CUSTOMERS_API_KEY"),
      customers_level_2: GlobalConfig.get("SENDGRID_GR_CUSTOMERS_LEVEL_2_API_KEY")
    }
  end

  def initialize(email)
    @email = email
  end

  def detailed_status(lists: ALL_SUPPRESSION_LISTS)
    sendgrid_subusers.each_with_object(lists.index_with { [] }) do |(subuser, api_key), result|
      suppression = sendgrid(api_key).client.suppression
      lists.each do |list|
        parsed_body = suppression.public_send(list)._(email).get.parsed_body
        next if parsed_body.blank?
        raise "Unexpected SendGrid response shape: #{parsed_body.inspect}" unless parsed_body.is_a?(Array)

        parsed_body.each do |entry|
          raise "Unexpected SendGrid entry shape: #{entry.inspect}" unless entry.is_a?(Hash)
          result[list] << {
            subuser:,
            reason: entry[:reason],
            created_at: entry[:created] ? Time.zone.at(entry[:created]).iso8601 : nil,
          }
        end
      rescue => e
        ErrorNotifier.notify(e)
        Rails.logger.info "[EmailSuppressionManager] Error parsing SendGrid #{list} response for #{subuser}: #{e.message}"
      end
    end
  end

  def remove_from_lists(lists)
    lists = Array(lists).map(&:to_sym)
    sendgrid_subusers.each_with_object(lists.index_with { [] }) do |(subuser, api_key), result|
      suppression = sendgrid(api_key).client.suppression
      lists.each do |list|
        next unless successful_response?(suppression.public_send(list)._(email).delete.status_code)
        result[list] << subuser
      end
    end
  end

    private
      attr_reader :email

      def sendgrid(api_key)
        SendGrid::API.new(api_key:)
      end

      def successful_response?(status_code)
        (200..299).include?(status_code.to_i)
      end

      def sendgrid_subusers
        self.class.subuser_api_keys
      end
end
