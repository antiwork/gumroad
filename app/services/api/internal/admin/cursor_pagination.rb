# frozen_string_literal: true

# Keyset pagination helper for NOT NULL sort columns.
class Api::Internal::Admin::CursorPagination
  class InvalidCursor < StandardError; end

  class << self
    def encode(payload)
      Base64.urlsafe_encode64(verifier.generate(JSON.dump(payload)))
    end

    def decode(token)
      raise InvalidCursor unless token.is_a?(String) && token.present?

      payload = JSON.parse(verifier.verify(Base64.urlsafe_decode64(token)))
      raise InvalidCursor unless payload.is_a?(Hash)

      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, JSON::ParserError, EncodingError
      raise InvalidCursor
    end

    def paginate(scope, cursor: nil, limit: 20, order: [[:created_at, :desc], [:id, :desc]])
      limit = Integer(limit)
      raise ArgumentError, "limit must be positive" if limit <= 0

      normalized_order = normalize_order(order)
      relation = scope.reorder(nil)
      relation = apply_cursor(relation, cursor, normalized_order) if cursor.present?
      relation = relation.order(Arel.sql(order_sql(scope.klass, normalized_order)))
      records = relation.limit(limit + 1).to_a
      page_records = records.first(limit)
      next_cursor = records.length > limit ? encode(cursor_payload(page_records.last, normalized_order)) : nil

      [page_records, next_cursor]
    end

    private
      def verifier
        Rails.application.message_verifier(:admin_api_cursor)
      end

      def normalize_order(order)
        raise ArgumentError, "order must be present" if order.blank?

        order.map do |column, direction|
          direction = direction.to_s.to_sym
          raise ArgumentError, "invalid order direction" unless %i[asc desc].include?(direction)

          [column.to_s, direction]
        end
      end

      def apply_cursor(relation, cursor, normalized_order)
        payload = decode(cursor)
        validate_cursor_keys!(payload, normalized_order)
        values = cast_cursor_values(relation.klass, payload, normalized_order)
        relation.where(*cursor_condition(relation.klass, normalized_order, values))
      end

      def validate_cursor_keys!(payload, normalized_order)
        expected_keys = normalized_order.map(&:first)
        return if payload.keys.sort == expected_keys.sort

        raise InvalidCursor
      end

      def cast_cursor_values(model, payload, normalized_order)
        normalized_order.map do |column, _direction|
          model.type_for_attribute(column).cast(payload.fetch(column))
        end
      end

      def cursor_condition(model, normalized_order, values)
        if normalized_order.map(&:second).uniq.one?
          direction = normalized_order.first.second
          comparator = direction == :desc ? "<" : ">"
          placeholders = (["?"] * normalized_order.length).join(", ")

          ["(#{column_list_sql(model, normalized_order)}) #{comparator} (#{placeholders})", *values]
        else
          mixed_direction_cursor_condition(model, normalized_order, values)
        end
      end

      def mixed_direction_cursor_condition(model, normalized_order, values)
        sql_fragments = []
        bind_values = []

        normalized_order.each_with_index do |(column, direction), index|
          prefix_fragments = normalized_order.first(index).map { |prefix_column, _| "#{column_sql(model, prefix_column)} = ?" }
          comparator = direction == :desc ? "<" : ">"
          sql_fragments << "(#{(prefix_fragments + ["#{column_sql(model, column)} #{comparator} ?"]).join(" AND ")})"
          bind_values.concat(values.first(index))
          bind_values << values[index]
        end

        [sql_fragments.join(" OR "), *bind_values]
      end

      def order_sql(model, normalized_order)
        normalized_order.map do |column, direction|
          "#{column_sql(model, column)} #{direction.to_s.upcase}"
        end.join(", ")
      end

      def column_list_sql(model, normalized_order)
        normalized_order.map { |column, _direction| column_sql(model, column) }.join(", ")
      end

      def column_sql(model, column)
        "#{model.quoted_table_name}.#{model.connection.quote_column_name(column)}"
      end

      def cursor_payload(record, normalized_order)
        normalized_order.to_h do |column, _direction|
          [column, serialize_value(record.public_send(column))]
        end
      end

      def serialize_value(value)
        case value
        when Time, ActiveSupport::TimeWithZone
          value.iso8601(6)
        when Date, DateTime
          value.iso8601
        else
          value
        end
      end
  end
end
