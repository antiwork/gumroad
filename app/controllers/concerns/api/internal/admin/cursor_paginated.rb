# frozen_string_literal: true

module Api::Internal::Admin::CursorPaginated
  extend ActiveSupport::Concern

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  included do
    rescue_from Api::Internal::Admin::CursorPagination::InvalidCursor do |_|
      render json: { success: false, message: "invalid cursor" }, status: :bad_request
    end
  end

  private
    def cursor_limit
      requested_limit = Integer(params[:limit], exception: false)
      return DEFAULT_LIMIT if requested_limit.blank? || requested_limit <= 0

      [requested_limit, MAX_LIMIT].min
    end

    def paginate_with_cursor(scope, order:)
      limit = cursor_limit
      records, next_cursor = Api::Internal::Admin::CursorPagination.paginate(
        scope,
        cursor: params[:cursor].presence,
        limit:,
        order:
      )

      [records, { next: next_cursor, limit: }]
    end
end
