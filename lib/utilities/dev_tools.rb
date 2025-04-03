# frozen_string_literal: true

class DevTools
  class << self
    # Useful in admin for the same reasons as `delete_all_indices_and_reindex_all`, but when you
    # don't want to index *everything* because you're connected to a copy of the production DB,
    # which has too many records for that to be practical.
    def reindex_all_for_user(user_id_or_record)
      ActiveRecord::Base.connection.enable_query_cache!
      user = user_id_or_record.is_a?(User) ? user_id_or_record : User.find(user_id_or_record)
      without_loggers do
        rel = Installment.where(seller_id: user.id)
        print "Importing installments seller_id=#{user.id} => #{rel.count} records..."
        es_import_with_time(rel)

        rel = user.purchased_products
        print "Importing purchased products of user with id #{user.id} => #{rel.count} records..."
        es_import_with_time(rel)

        rel = Purchase.where(purchaser_id: user.id)
        print "Importing purchases where purchaser_id=#{user.id} => #{rel.count} records..."
        es_import_with_time(rel)

        rel = Purchase.where(purchaser_id: user.id)
        print "Importing products from purchases where purchaser_id=#{user.id} => #{rel.count} records..."
        es_import_with_time(rel)

        rel = Purchase.where(seller_id: user.id)
        print "Importing purchases where seller_id=#{user.id} => #{rel.count} records..."
        es_import_with_time(rel)

        rel = Purchase.joins(:affiliate_credit).where(affiliate_credit: { affiliate_user_id: user.id })
        print "Importing purchases where affiliate_credit.affiliate_user_id=#{user.id} => #{rel.count} records..."
        es_import_with_time(rel)

        [Link, Balance].each do |model|
          rel = model.where(user_id: user.id)
          print "Importing #{model.name} user_id=#{user.id} => #{rel.count} records..."
          es_import_with_time(rel)
        end
      end

      nil
    ensure
      ActiveRecord::Base.connection.disable_query_cache!
    end

    # Useful in development to update your local indices if:
    # - something changed in the ES indices setup
    # - you manually changed something in your database
    def delete_all_indices_and_reindex_all
      if Rails.env.production? # safety first, in case the method name was not clear enough
        raise "This method recreates existing ES indices, which should never happen in production."
      end
      ActiveRecord::Base.connection.enable_query_cache!
      without_loggers do
        [Purchase, Link, Balance, Installment].each do |model|
          print "Recreating index and importing #{model.name} => #{model.count} records..."
          es_import_with_time(model, force: true)
        end
        print "Recreating index #{ConfirmedFollowerEvent.index_name} and importing confirmed followers => #{Follower.active.count} records..."
        do_with_time do
          ConfirmedFollowerEvent.__elasticsearch__.create_index!(force: true)
          Follower.active.group(:followed_id).each do |follower|
            DevTools.reimport_follower_events_for_user!(follower.user)
          end
        end
        [ProductPageView].each do |model|
          print "Recreating index #{model.index_name}"
          do_with_time do
            model.__elasticsearch__.create_index!(force: true)
          end
        end
      end

      nil
    ensure
      ActiveRecord::Base.connection.disable_query_cache!
    end

    # Warning: This method is destructive and should only be used:
    # - When importing existing data for the very first time for a user
    # - In tests
    # - If the existing data was somehow seriously corrupted
    #
    # It's destructive because we only store in the DB the last time a follower was either
    # confirmed (`confirmed_at`) OR destroyed (`deleted_at`).
    # If someone was followed and unfollowed by the same person, running this will lose that information,
    # and both the follow and unfollow will disappear from the stats.
    def reimport_follower_events_for_user!(user)
      cut_off_time = Time.current # prevents a race-condition that would result in adding the same event twice
      EsClient.delete_by_query(
        index: ConfirmedFollowerEvent.index_name,
        body: {
          query: {
            bool: {
              filter: [{ term: { followed_user_id: user.id } }],
              must: [{ range: { timestamp: { lte: cut_off_time } } }]
            }
          }
        }
      )

      user.followers.active.where("confirmed_at < ?", cut_off_time).find_each do |follower|
        EsClient.index(
          index: ConfirmedFollowerEvent.index_name,
          id: SecureRandom.uuid,
          body: {
            name: "added",
            timestamp: follower.confirmed_at,
            follower_id: follower.id,
            followed_user_id: follower.followed_id,
            follower_user_id: follower.follower_user_id,
            email: follower.email,
          }
        )
      end
    end

    # Useful for use inside and outside this class to process large amount of data without logs
    def without_loggers
      es_logger = EsClient.transport.logger
      ar_logger = ActiveRecord::Base.logger
      EsClient.transport.logger = Logger.new(File::NULL)
      ActiveRecord::Base.logger = Logger.new(File::NULL)
      yield
    ensure
      EsClient.transport.logger = es_logger
      ActiveRecord::Base.logger = ar_logger
    end

    private
      def do_with_time(&block)
        duration = Benchmark.measure(&block).real.round(2)
        puts " done in #{duration}s"
      end

      def es_import_with_time(rel, force: false)
        do_with_time { rel.import(force:) }
      end
  end
end
