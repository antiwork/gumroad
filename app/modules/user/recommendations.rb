# frozen_string_literal: true

module User::Recommendations
  def recommendable?
    recommendable_reasons.values.all?
  end

  # All of the factors(values/records/etc.) which influence the return value of this method should be watched.
  # Whenever any of those factors change, a `SendToElasticsearchWorker` job must be enqueued to update the `is_recommendable`
  # field in the Elasticsearch index.
  def recommendable_reasons
    {
      name_filled: name_or_username.present?,
      not_deleted: !deleted?,
      payout_filled: !(payment_address.blank? && active_bank_account.blank? && stripe_connect_account.blank? && !has_paypal_account_connected?),
    }
  end
end
