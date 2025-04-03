# frozen_string_literal: true

class PaginatedCommunityChatMessagesPresenter
  include Pagy::Backend

  MESSAGES_PER_PAGE = 100

  def initialize(community:, timestamp:, fetch_type:)
    @community = community
    @timestamp = timestamp
    @fetch_type = fetch_type

    raise ArgumentError, "Invalid timestamp" unless timestamp.present?
    raise ArgumentError, "Invalid fetch type" unless %w[older newer around].include?(fetch_type)
  end

  def props
    base_query = community.community_chat_messages.alive.includes(:community, user: :avatar_attachment)
    messages, next_older_timestamp, next_newer_timestamp = fetch_messages(base_query)

    {
      messages: messages.map { |message| CommunityChatMessagePresenter.new(message:).props },
      next_older_timestamp:,
      next_newer_timestamp:
    }
  end

  private
    attr_reader :community, :timestamp, :fetch_type

    def fetch_messages(base_query)
      case fetch_type
      when "older"
        result = base_query.order(created_at: :desc).where("created_at <= ?", timestamp).limit(MESSAGES_PER_PAGE + 1).to_a
        messages = result.take(MESSAGES_PER_PAGE)
        next_older_timestamp = result.size > MESSAGES_PER_PAGE ? result.last.created_at.iso8601 : nil
        next_newer_timestamp = base_query.order(created_at: :asc).where("created_at > ?", timestamp).limit(1).first&.created_at&.iso8601

        [messages, next_older_timestamp, next_newer_timestamp]
      when "newer"
        result = base_query.order(created_at: :asc).where("created_at >= ?", timestamp).limit(MESSAGES_PER_PAGE + 1).to_a
        messages = result.take(MESSAGES_PER_PAGE)
        next_older_timestamp = base_query.order(created_at: :desc).where("created_at < ?", timestamp).limit(1).first&.created_at&.iso8601
        next_newer_timestamp = result.size > MESSAGES_PER_PAGE ? result.last.created_at.iso8601 : nil

        [messages, next_older_timestamp, next_newer_timestamp]
      when "around"
        half_per_page = MESSAGES_PER_PAGE / 2

        older = base_query.order(created_at: :desc).where("created_at < ?", timestamp).limit(half_per_page + 1).to_a
        newer = base_query.order(created_at: :asc).where("created_at >= ?", timestamp).limit(half_per_page + 1).to_a

        messages = older.take(half_per_page) + newer.take(half_per_page)
        next_older_timestamp = older.size > half_per_page ? older.last.created_at.iso8601 : nil
        next_newer_timestamp = newer.size > half_per_page ? newer.last.created_at.iso8601 : nil

        [messages.sort_by(&:created_at), next_older_timestamp, next_newer_timestamp]
      end
    end
end
