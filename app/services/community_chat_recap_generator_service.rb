# frozen_string_literal: true

class CommunityChatRecapGeneratorService
  MAX_MESSAGES_TO_SUMMARIZE = 1000
  MAX_SUMMARY_LENGTH = 500
  MIN_SUMMARY_BULLET_POINTS = 1
  MAX_SUMMARY_BULLET_POINTS = 5
  OPENAI_REQUEST_TIMEOUT_IN_SECONDS = 10
  DAILY_SUMMARY_SYSTEM_PROMPT = <<~PROMPT
    You are an AI assistant that creates concise, informative daily summaries of community chat conversations.

    Your task is to analyze the provided chat messages and create a summary with minimum #{MIN_SUMMARY_BULLET_POINTS} and maximum #{MAX_SUMMARY_BULLET_POINTS} bullet points (maximum #{MAX_SUMMARY_LENGTH} characters) highlighting key discussions, questions answered, important announcements, or decisions made. Messages from the creator of the community are highlighted with [CREATOR], refer to them as "creator". Refer to each customer as "a customer" and never mention their actual names. Make important words/phrases bold using <strong> tags. Do not say anything that was not said in the messages.

    Format your response in an HTML unordered list exactly like this:

    <ul>
      <li>Summary bullet point 1</li>
      <li>Summary bullet point 2</li>
    </ul>

    Keep the summary conversational and easy to read.
    Make sure to include all significant topics discussed.
    Don't include usernames or timestamps in your summary.
    If there are very few messages, keep the summary brief but informative.
  PROMPT
  WEEKLY_SUMMARY_SYSTEM_PROMPT = <<~PROMPT
    You are an AI assistant that creates concise, informative weekly summaries of community chat conversations.

    Your task is to analyze the provided daily summaries and create a weekly summary with minimum #{MIN_SUMMARY_BULLET_POINTS} and maximum #{MAX_SUMMARY_BULLET_POINTS} bullet points (maximum #{MAX_SUMMARY_LENGTH} characters) highlighting key discussions, questions answered, important announcements, or decisions made. Make important words/phrases bold using <strong> tags.

    Format your response in an HTML unordered list exactly like this:

    <ul>
      <li>Summary bullet point 1</li>
      <li>Summary bullet point 2</li>
    </ul>

    Keep the summary conversational and easy to read.
    Make sure to include all significant topics discussed.
    Don't include usernames or timestamps in your summary.
    If there are very few daily summaries, keep the weekly summary brief but informative.
  PROMPT

  def initialize(community_chat_recap:)
    @community_chat_recap = community_chat_recap
    @community = community_chat_recap.community
    @recap_run = community_chat_recap.community_chat_recap_run
    @recap_frequency = recap_run.recap_frequency
    @from_date = recap_run.from_date
    @to_date = recap_run.to_date
  end

  def process
    return if community_chat_recap.status_finished?

    recap_frequency == "daily" ? create_daily_recap : create_weekly_recap
  end

  private
    attr_reader :community_chat_recap, :community, :recap_run, :recap_frequency, :from_date, :to_date

    def create_daily_recap
      messages = community.community_chat_messages
                          .includes(:user)
                          .alive
                          .where(created_at: from_date..to_date)
                          .order(created_at: :asc)
                          .limit(MAX_MESSAGES_TO_SUMMARIZE)
      summary, input_token_count, output_token_count = if messages.present?
        generate_daily_summary(messages)
      else
        ["", 0, 0]
      end

      community_chat_recap.assign_attributes(
        seller: community.seller,
        summary:,
        summarized_message_count: messages.size,
        input_token_count:,
        output_token_count:,
        status: "finished",
        error_message: nil
      )
      community_chat_recap.save!
    end

    def create_weekly_recap
      daily_recap_runs = CommunityChatRecapRun.includes(:community_chat_recaps).where(recap_frequency: "daily").between(from_date, to_date).where(community_chat_recaps: { community:, status: "finished" })
      daily_recaps = daily_recap_runs.map(&:community_chat_recaps).flatten.sort_by(&:created_at)
      summary, input_token_count, output_token_count = if daily_recaps.present?
        generate_weekly_summary(daily_recaps)
      else
        ["", 0, 0]
      end

      community_chat_recap.assign_attributes(
        seller: community.seller,
        summary:,
        summarized_message_count: daily_recaps.sum(&:summarized_message_count),
        input_token_count:,
        output_token_count:,
        status: "finished",
        error_message: nil
      )
      community_chat_recap.save!
    end

    def generate_daily_summary(messages)
      formatted_messages = messages.map do |message|
        timestamp = message.created_at.strftime("%Y-%m-%d %H:%M:%S")
        "[#{timestamp}] [Name: #{message.user.display_name}] #{message.user.id == community.seller_id ? "[CREATOR]" : ""}: #{message.content}"
      end.join("\n\n")

      Rails.logger.info("Formatted messages used for generating daily summary: #{formatted_messages}") if Rails.env.development?

      with_retries("daily summary") do
        response = OpenAI::Client.new.chat(
          parameters: {
            model: "gpt-4o-mini",
            messages: [
              { role: "system", content: DAILY_SUMMARY_SYSTEM_PROMPT },
              { role: "user", content: "Here are today's chat messages in the community:\n\n#{formatted_messages}" }
            ],
            temperature: 0.7
          }
        )

        content = response.dig("choices", 0, "message", "content")
        summary_match = content.match(/(<ul>.+?<\/ul>)/m)
        summary = summary_match ? summary_match[1].strip : content.strip
        input_token_count = response.dig("usage", "prompt_tokens")
        output_token_count = response.dig("usage", "completion_tokens")

        [summary, input_token_count, output_token_count]
      end
    end

    def generate_weekly_summary(daily_recaps)
      formatted_summaries = daily_recaps.map(&:summary).join("\n")

      Rails.logger.info("Formatted daily summaries used for generating weekly summary: #{formatted_summaries}") if Rails.env.development?

      return ["", 0, 0] if formatted_summaries.strip.blank?

      with_retries("weekly summary") do
        response = OpenAI::Client.new(request_timeout: OPENAI_REQUEST_TIMEOUT_IN_SECONDS).chat(
          parameters: {
            model: "gpt-4o-mini",
            messages: [
              { role: "system", content: WEEKLY_SUMMARY_SYSTEM_PROMPT },
              { role: "user", content: "Here are the daily summaries:\n\n#{formatted_summaries}" }
            ],
            temperature: 0.7
          }
        )

        content = response.dig("choices", 0, "message", "content")
        summary_match = content.match(/(<ul>.+?<\/ul>)/m)
        summary = summary_match ? summary_match[1].strip : content.strip
        input_token_count = response.dig("usage", "prompt_tokens")
        output_token_count = response.dig("usage", "completion_tokens")

        [summary, input_token_count, output_token_count]
      end
    end

    def with_retries(operation, max_tries: 3, delay: 1)
      tries = 0
      begin
        tries += 1
        yield
      rescue => e
        if tries < max_tries
          Rails.logger.info("Failed to generate #{operation}, attempt #{tries}/#{max_tries} (ID: #{community_chat_recap.id}): #{e.message}")
          sleep(delay)
          retry
        else
          Rails.logger.error("Failed to generate #{operation} after #{max_tries} attempts (ID: #{community_chat_recap.id}): #{e.message}")
          raise
        end
      end
    end
end
