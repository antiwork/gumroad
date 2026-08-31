# frozen_string_literal: true

class RedisKey
  class << self
    def total_made = "homepage:total_made"
    def number_of_creators = "company_page:number_of_creators"
    def prev_week_payout_usd = "homepage:prev_week_payout_usd"
    def balance_stats_sales_caching_threshold = "balance_stats:sales_caching_threshold"
    def balance_stats_users_excluded_from_caching = "balance_stats:users_excluded_from_caching"
    def balance_stats_scheduler_minutes_between_jobs = "balance_stats_scheduler:minutes_between_jobs"
    def elasticsearch_indexer_worker_ignore_404_errors_on_indices = "elasticsearch_indexer_worker:ignore_404_errors_on_indices"
    def product_presenter_existing_product_files_limit = "product_presenter:existing_product_files_limit"
    def seller_analytics_cache_version = "seller_analytics:cache_version"
    def cf_cache_invalidated_extensions_and_cache_keys = "cf_cache_invalidated_extensions_and_cache_keys"
    def user_ids_with_payment_requirements_key = "user_ids_with_payment_requirements_key"
    def card_testing_product_watch_minutes = "card_testing_product_watch_minutes"
    def card_testing_product_max_failed_purchases_count = "card_testing_product_max_failed_purchases_count"
    def card_testing_product_block_hours = "card_testing_product_block_hours"
    def card_testing_max_number_of_failed_purchases_in_a_row = "card_testing_max_number_of_failed_purchases_in_a_row"
    def card_testing_failed_purchases_in_a_row_watch_days = "card_testing_failed_purchases_in_a_row_watch_days"
    def followers_import_limit = "followers_import:limit"
    def force_product_id_timestamp = "force_product_id_timestamp"
    def api_v2_sales_deprecated_pagination_query_timeout = "api_v2_sales_deprecated_pagination_query_timeout"
    def api_v2_sales_page_key_query_timeout = "api_v2_sales_page_key_query_timeout"
    def free_purchases_watch_hours = "free_purchases_watch_hours"
    def max_allowed_free_purchases_of_same_product = "max_allowed_free_purchases_of_same_product"
    def auto_topup_negative_destination_balance_last_amount(merchant_account_id) = "auto_topup_negative_destination_balance:#{merchant_account_id}:last_amount_cents"
    def ai_request_throttle(user_id) = "ai_request_throttle:#{user_id}"
    def agent_request_throttle(user_id) = "agent_request_throttle:#{user_id}"
    def gumhead_gateway_throttle(user_id) = "gumhead_gateway_throttle:#{user_id}"
    def gumhead_gateway_in_flight(user_id) = "gumhead_gateway_in_flight:#{user_id}"
    def gumhead_model_map = "gumhead_model_map"
    def gumhead_client_versions = "gumhead_client_versions"
    def agent_turn_status(user_id, client_turn_id) = "agent_turn_status:#{user_id}:#{client_turn_id}"
    def agent_custom_html_preview(user_id, token) = "agent_custom_html_preview:#{user_id}:#{token}"
    def agent_custom_html_preview_index(user_id) = "agent_custom_html_preview_index:#{user_id}"
    def fraudulent_free_purchases_block_hours = "fraudulent_free_purchases_block_hours"
    def recaptcha_score_threshold(surface) = "recaptcha_score_threshold:#{surface}"
    def recaptcha_challenge_offer(browser_guid) = "recaptcha_challenge_offer:#{browser_guid}"
    def sales_related_products_internal_limit = "sales_related_products_internal_limit"
    def recommended_products_associated_product_ids_limit = "recommended_products_associated_product_ids_limit"
    def blast_recipients_slice_size = "blast:recipients_slice_size"
    def grouped_receipt_send_claim(email, digest) = "grouped_receipt_send_claim:#{Digest::SHA256.hexdigest(email.to_s.downcase)}:#{digest}"
    def blast_sent_emails(blast_id) = "blast:#{blast_id}:sent_emails"
    def blast_audience_snapshot(blast_id) = "blast:#{blast_id}:audience_snapshot"
    def blast_non_opener_emails(blast_id) = "blast:#{blast_id}:non_opener_emails"
    def blast_pending_recipients(blast_id) = "blast:#{blast_id}:pending_recipients"
    def blast_done_slices(blast_id) = "blast:#{blast_id}:done_slices"
    def blast_child_split_threshold = "blast:child_split_threshold"
    def blast_child_slice_size = "blast:child_slice_size"
    def stalled_blast_auto_resumed(blast_id) = "blast:#{blast_id}:auto_resumed"
    def stalled_blast_completion_resumed(blast_id) = "blast:#{blast_id}:completion_resumed"
    def workflow_installment_rule_version(installment_id) = "workflow_installment_rule:#{installment_id}:version"
    def workflow_installment_rule_pending_token(installment_id) = "workflow_installment_rule:#{installment_id}:pending_token"
    def audience_member_load_max_execution_time_seconds = "audience_member_load:max_execution_time_seconds"
    def impersonated_user(admin_user_id) = "impersonated_user_by_admin_#{admin_user_id}"
    def undeliverable_ping_subscription_notified(resource_subscription_id, reason) = "undeliverable_ping_subscription:#{resource_subscription_id}:#{reason}"
    def undeliverable_ping_subscription_enqueued(resource_subscription_id, reason) = "undeliverable_ping_subscription_enqueued:#{resource_subscription_id}:#{reason}"
    def gumroad_day_date = "gumroad_day_date"
    def update_cached_srpis_job_delay_hours = "update_cached_srpis_job_delay_hours"
    def tip_options = "tip_options"
    def default_tip_option = "default_tip_option"
    def create_canada_monthly_sales_report_job_max_execution_time_seconds = "create_canada_monthly_sales_report_job:max_execution_time_seconds"
    def generate_sales_report_job_max_execution_time_seconds = "generate_sales_report_job:max_execution_time_seconds"
    def generate_canada_sales_report_job_max_execution_time_seconds = "generate_canada_sales_report_job:max_execution_time_seconds"
    def create_vat_report_job_max_execution_time_seconds = "create_vat_report_job:max_execution_time_seconds"
    def transcoded_videos_recentness_limit_in_months = "transcoded_videos_recentness_limit_in_months"
    def generate_fees_by_creator_location_job_max_execution_time_seconds = "generate_fees_by_creator_location_job:max_execution_time_seconds"
    def create_global_sales_tax_summary_report_job_max_execution_time_seconds = "create_global_sales_tax_summary_report_job:max_execution_time_seconds"
    def ytd_sales_report_emails = "reports:ytd_sales_report_emails"
    def failed_seller_purchases_watch_minutes = "failed_seller_purchases_watch_minutes"
    def max_seller_failed_purchases_price_cents = "max_seller_failed_purchases_price_cents"
    def seller_age_threshold_days = "seller_age_threshold_days"
    def sales_report_jobs = "sales_report_jobs"
    def acme_challenge(token) = "acme_challenge:#{token}"
    def walks_app_attest_challenge(challenge) = "walks_app_attest_challenge:#{challenge}"
    def paypal_topup_needed = "paypal:topup_needed"
    # Set (with a TTL) by each weekly payout batch job while it runs, so the
    # deploy pipeline can ask "is a payout batch in flight right now?" instead
    # of freezing deploys on a fixed clock window. See HealthcheckController#payouts.
    def payout_batch_in_flight = "payouts:batch_in_flight"
    # Same idea for the non-payout jobs a deploy must not interrupt (long report
    # builds and the like, which restart from zero when their worker is recycled).
    # See LongRunningJobTracking and HealthcheckController#long_running_jobs.
    def long_running_jobs_in_flight = "deploy:long_running_jobs_in_flight"
    def stripe_balance_topup_needed = "stripe:balance_topup_needed"
    def min_successful_purchases_in_last_10_minutes = "healthcheck:min_successful_purchases_in_last_10_minutes"
    def email_router_fallback(user_id) = "email_router_fallback:#{user_id}"
    def mobile_minimum_version = "mobile:minimum_version"
    def mobile_minimum_update_created_at = "mobile:minimum_update_created_at"
    def gmail_abuse_normalized_emails = "gmail_abuse:normalized_emails"
    # Marks that RequeueTransientlyFailedPayoutsJob has already reported this seller as having
    # exhausted its requeue attempts for this payout period. Once requeueing stops the seller's
    # failure count stops growing, so without this the daily run would re-alert on the same
    # seller for the rest of the period.
    def transient_payout_requeue_exhaustion_reported(user_id, payout_period_end_date) = "payouts:transient_requeue_exhaustion_reported:#{payout_period_end_date}:#{user_id}"
    # Marks that the seller was told this purchase's receipt has no evidence of reaching the buyer.
    # Permanent, so the nightly sweep reports each buyer once. See UndeliveredReceiptNotifier.
    def undelivered_receipt_notified(purchase_id) = "undelivered_receipt_notified:#{purchase_id}"
    # High-water mark for AlertSellersOfUndeliveredReceiptsJob: the last email_infos id it judged.
    def undelivered_receipt_sweep_cursor = "undelivered_receipt_sweep:cursor"
    def stale_block_sweep_cursor = "stale_block_sweep:cursor"
    # How far RecoverStrandedBuyersJob has rotated a SPECIFIC oversized-bucket page (bucket_id,
    # cycle) so a run that hits RUN_BUDGET partway through doesn't restart that page at the same
    # buyer next occurrence. Keyed per page, not per bucket: a bucket's several pages are all
    # reached in turn, and a cursor shared across them would accumulate identically regardless of
    # which page ran, so on same-sized pages it always lands back on the same prefix.
    def recover_stranded_buyers_page_cursor(page_key) = "recover_stranded_buyers:page_cursor:#{page_key.join(":")}"
    # High-water mark for RepairOrderChargeOutcomesJob's backlog pass: the last orders id it walked.
    def order_charge_outcome_repair_cursor = "order_charge_outcome_repair:cursor"
    # Fixed at lap start so the walk keeps making forward progress even while new failing orders
    # keep arriving above it. See RepairOrderChargeOutcomesJob.
    def order_charge_outcome_repair_lap_ceiling = "order_charge_outcome_repair:lap_ceiling"
    # High-water mark for AlertOnStripeDobDriftJob: the last merchant_accounts id it compared.
    def stripe_dob_drift_sweep_cursor = "stripe_dob_drift_sweep:cursor"
    # Purchases whose notice was claimed but never transmitted. The cursor is already past their
    # email_infos rows, so this set is the only thing that brings them back.
    def undelivered_receipt_pending_retry = "undelivered_receipt_sweep:pending_retry"
    # Claims the seller notification for a review so the message-less delayed render and the
    # blank→present immediate send can't both deliver when the buyer's text lands mid-flight. Held
    # only for the length of one render; `product_reviews.seller_notified_at` is what records that
    # the seller was told. See ContactingCreatorMailer#review_submitted.
    def product_review_seller_notified(review_id) = "product_review_seller_notified:#{review_id}"
    def workflow_seller_fanout_lock(seller_id) = "workflow_seller_fanout_lock:#{seller_id}"
    def workflow_seller_fanout_lock_ttl_seconds = "workflow_seller_fanout_lock_ttl_seconds"
    def workflow_seller_fanout_retry_seconds = "workflow_seller_fanout_retry_seconds"
    def workflow_immediate_fanout_threshold = "workflow_immediate_fanout_threshold"
    def workflow_immediate_enqueue_per_second = "workflow_immediate_enqueue_per_second"
    def workflow_immediate_fanout_max_spread_seconds = "workflow_immediate_fanout_max_spread_seconds"
    def seller_large_blast_threshold = "seller_large_blast_threshold"
    def seller_large_blast_quota(seller_id, day) = "seller_large_blast_quota:#{seller_id}:#{day}"
  end
end
