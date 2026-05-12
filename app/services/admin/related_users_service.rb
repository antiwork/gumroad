# frozen_string_literal: true

class Admin::RelatedUsersService
  DEFAULT_LIMIT = 50
  MAX_LIMIT = 50
  VALID_SIGNALS = %w[ip payment_address card_fingerprint].freeze
  IP_COLUMNS = %i[account_created_ip current_sign_in_ip last_sign_in_ip].freeze
  private_constant :IP_COLUMNS

  Result = Struct.new(:signals_evaluated, :per_signal_limit, :related_users, :truncated, keyword_init: true)
  Relation = Struct.new(:user_id, :signal, :shared_value, :via, keyword_init: true)
  private_constant :Relation

  def initialize(user, signals: VALID_SIGNALS, limit: DEFAULT_LIMIT)
    @target = user
    @signals = Array(signals).map(&:to_s) & VALID_SIGNALS
    @limit = limit.to_i.clamp(1, MAX_LIMIT)
  end

  def call
    evaluated = []
    truncated = {}
    relations = []

    if @signals.include?("ip")
      evaluated << "ip" if target_ips.any?
      signal_relations, signal_truncated = ip_relations
      relations.concat(signal_relations)
      truncated["ip"] = signal_truncated
    end

    if @signals.include?("payment_address")
      if @target.payment_address.present?
        evaluated << "payment_address"
        signal_relations, signal_truncated = payment_address_relations
        relations.concat(signal_relations)
        truncated["payment_address"] = signal_truncated
      else
        truncated["payment_address"] = false
      end
    end

    if @signals.include?("card_fingerprint")
      if target_fingerprint.present?
        evaluated << "card_fingerprint"
        signal_relations, signal_truncated = card_fingerprint_relations
        relations.concat(signal_relations)
        truncated["card_fingerprint"] = signal_truncated
      else
        truncated["card_fingerprint"] = false
      end
    end

    Result.new(
      signals_evaluated: evaluated,
      per_signal_limit: @limit,
      related_users: dedup_and_rank(relations),
      truncated:
    )
  end

  private
    def target_ips
      @target_ips ||= IP_COLUMNS.map { @target.public_send(_1) }.compact_blank.uniq
    end

    def target_ip_columns_by_value
      @target_ip_columns_by_value ||= IP_COLUMNS.each_with_object(Hash.new { |hash, value| hash[value] = [] }) do |column, result|
        value = @target.public_send(column)
        result[value] << column.to_s if value.present?
      end
    end

    def target_fingerprint
      @target_fingerprint ||= @target.credit_card&.stripe_fingerprint
    end

    def ip_relations
      return [[], false] if target_ips.empty?

      rows = User
        .where("account_created_ip IN (:ips) OR current_sign_in_ip IN (:ips) OR last_sign_in_ip IN (:ips)", ips: target_ips)
        .where.not(id: @target.id)
        .order(updated_at: :desc, id: :desc)
        .limit(@limit + 1)
        .pluck(:id, :account_created_ip, :current_sign_in_ip, :last_sign_in_ip)

      truncated = rows.length > @limit
      grouped = rows.first(@limit).each_with_object({}) do |(user_id, account_created_ip, current_sign_in_ip, last_sign_in_ip), result|
        candidate_values = {
          "account_created_ip" => account_created_ip,
          "current_sign_in_ip" => current_sign_in_ip,
          "last_sign_in_ip" => last_sign_in_ip,
        }

        candidate_values.each do |column, value|
          next unless target_ip_columns_by_value.key?(value)

          relation = result[[user_id, value]] ||= Relation.new(user_id:, signal: "ip", shared_value: value, via: [])
          relation.via.concat(target_ip_columns_by_value[value])
          relation.via << column
        end
      end

      [grouped.values.each { _1.via = _1.via.uniq.sort_by { |column| IP_COLUMNS.map(&:to_s).index(column) } }, truncated]
    end

    def payment_address_relations
      ids = User
        .where(payment_address: @target.payment_address)
        .where.not(id: @target.id)
        .order(updated_at: :desc, id: :desc)
        .limit(@limit + 1)
        .pluck(:id)

      [
        ids.first(@limit).map { Relation.new(user_id: _1, signal: "payment_address", shared_value: @target.payment_address, via: nil) },
        ids.length > @limit,
      ]
    end

    def card_fingerprint_relations
      ids = User
        .joins(:credit_card)
        .where(credit_cards: { stripe_fingerprint: target_fingerprint })
        .where.not(id: @target.id)
        .order(updated_at: :desc, id: :desc)
        .limit(@limit + 1)
        .pluck(:id)

      [
        ids.first(@limit).map { Relation.new(user_id: _1, signal: "card_fingerprint", shared_value: nil, via: nil) },
        ids.length > @limit,
      ]
    end

    def dedup_and_rank(relations)
      relations_by_user_id = relations.group_by(&:user_id)
      return [] if relations_by_user_id.empty?

      users_by_id = User.where(id: relations_by_user_id.keys).index_by(&:id)
      last_status_changed_at_by_user_id = last_status_changed_at_by_user_id(users_by_id.keys)

      users_by_id.values
        .sort_by { |user| [-relations_by_user_id[user.id].map(&:signal).uniq.length, -user.updated_at.to_i, -user.id] }
        .map do |user|
          {
            id: user.external_id,
            email: user.email,
            name: user.name,
            deleted_at: user.deleted_at&.as_json,
            risk_state: Admin::UserRiskStatePresenter.new(user, last_status_changed_at: last_status_changed_at_by_user_id[user.id]).props,
            relations: relations_by_user_id[user.id].map { serialize_relation(_1) },
          }
        end
    end

    def last_status_changed_at_by_user_id(user_ids)
      Comment
        .where(
          commentable_type: User.name,
          commentable_id: user_ids,
          comment_type: Admin::UserRiskStatePresenter::RISK_STATE_COMMENT_TYPES
        )
        .group(:commentable_id)
        .maximum(:created_at)
    end

    def serialize_relation(relation)
      {
        signal: relation.signal,
        shared_value: relation.shared_value,
      }.tap do |payload|
        payload[:via] = relation.via if relation.via.present?
      end
    end
end
