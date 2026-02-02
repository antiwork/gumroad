# frozen_string_literal: true

class CommunityMessagesPresenter
  MESSAGES_PER_PAGE = 100

  def initialize(community:, current_user:, cursor: nil, direction: nil)
    @community = community
    @current_user = current_user
    @cursor = cursor || last_read_timestamp || Time.current.iso8601
    @direction = direction || "around"
  end

  def props
    base_query = community.community_chat_messages.alive.includes(:community, user: :avatar_attachment)
    messages, next_older_timestamp, next_newer_timestamp = fetch_messages(base_query)

    {
      messages: messages.map { |message| CommunityChatMessagePresenter.new(message:).props },
      next_older_timestamp:,
      next_newer_timestamp:,
      current_cursor: cursor
    }
  end

  private
    attr_reader :community, :current_user, :cursor, :direction

    def last_read_timestamp
      LastReadCommunityChatMessage
        .includes(:community_chat_message)
        .find_by(user_id: current_user.id, community_id: community.id)
        &.community_chat_message
        &.created_at
        &.iso8601
    end

    def fetch_messages(base_query)
      case direction
      when "older"
        fetch_older_messages(base_query)
      when "newer"
        fetch_newer_messages(base_query)
      else
        fetch_around_messages(base_query)
      end
    end

    def fetch_older_messages(base_query)
      result = base_query.order(created_at: :desc).where("created_at <= ?", cursor).limit(MESSAGES_PER_PAGE + 1).to_a
      messages = result.take(MESSAGES_PER_PAGE)
      next_older_timestamp = result.size > MESSAGES_PER_PAGE ? result.last.created_at.iso8601 : nil
      next_newer_timestamp = base_query.order(created_at: :asc).where("created_at > ?", cursor).limit(1).first&.created_at&.iso8601

      [messages, next_older_timestamp, next_newer_timestamp]
    end

    def fetch_newer_messages(base_query)
      result = base_query.order(created_at: :asc).where("created_at >= ?", cursor).limit(MESSAGES_PER_PAGE + 1).to_a
      messages = result.take(MESSAGES_PER_PAGE)
      next_older_timestamp = base_query.order(created_at: :desc).where("created_at < ?", cursor).limit(1).first&.created_at&.iso8601
      next_newer_timestamp = result.size > MESSAGES_PER_PAGE ? result.last.created_at.iso8601 : nil

      [messages, next_older_timestamp, next_newer_timestamp]
    end

    def fetch_around_messages(base_query)
      half_per_page = MESSAGES_PER_PAGE / 2

      older = base_query.order(created_at: :desc).where("created_at < ?", cursor).limit(half_per_page + 1).to_a
      newer = base_query.order(created_at: :asc).where("created_at >= ?", cursor).limit(half_per_page + 1).to_a

      messages = older.take(half_per_page) + newer.take(half_per_page)
      next_older_timestamp = older.size > half_per_page ? older.last.created_at.iso8601 : nil
      next_newer_timestamp = newer.size > half_per_page ? newer.last.created_at.iso8601 : nil

      [messages.sort_by(&:created_at), next_older_timestamp, next_newer_timestamp]
    end
end
