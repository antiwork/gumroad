# frozen_string_literal: true

class AddProfilePictureUrlToUsers < ActiveRecord::Migration
  def up
    unless column_exists? :users, :profile_picture_url
      add_column :users, :profile_picture_url, :string
    end
    migrate_avatar_pictures
  end

  def down
    remove_column :users, :profile_picture_url
  end

  private
    # Data migration to migrate all the existing FB and Twitter Avatar profile
    # pictures from their columns out into the new profile_picture_url column.
    def migrate_avatar_pictures
      # Note: Twitter pics get preference before Facebook pictures.
      # Ensure idempotency so that we can rerun this migration without processing
      # all the data gain.
      # We have about 5000 records to update in total. Each of about 50 kbytes in size
      # so max. 250 MB of RAM. We should be fine doing this sequentially, since
      # image processing and network transfer time will exceed DB Update time.
      puts("Starting data migration of profile pictures")

      # Fetch all users with Twitter photos first
      all_users = User.where("(twitter_pic IS NOT NULL and twitter_pic not like '')").
          where("(profile_picture_url IS NULL or profile_picture_url like '')")
      puts("#{all_users.size} users need twitter pic to be migrated")
      all_users.each do |u|
        # note, the user.save_profile_pic_on_s3 hook will resize/convert/upload.
        puts("Migrating user_id: #{u.id} and url: #{u.twitter_pic}")
        u.profile_picture_url = u.twitter_pic
        u.save!
      end

      # Fetch all users with Facebook photo second
      all_users = User.where("(facebook_pic_large IS NOT NULL and facebook_pic_large not like '')").
          where("(twitter_pic IS NULL or twitter_pic like '')").
          where("(profile_picture_url IS NULL or profile_picture_url like '')")
      puts("#{all_users.size} users need facebook pic to be migrated")
      all_users.each do |u|
        # note, the user.save_profile_pic_on_s3 hook will resize/convert/upload.
        puts("Migrating user_id: #{u.id} and url: #{u.facebook_pic_large}")
        u.profile_picture_url = u.facebook_pic_large
        u.save!
      end

      puts("Data migration of profile pictures completed!")
    end
end
