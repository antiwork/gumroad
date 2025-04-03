# frozen_string_literal: true

class MigratePreviewImagesOnLinks < ActiveRecord::Migration
  def up
    migrate_preview_images
  end

  def down
    # the rollback has no effect!
  end



  private
    # Migrate all the preview images that were generated on Amazon S3 into the
    # proper size and format 300x300 PNG and save them again.
    def migrate_preview_images
      puts("Starting data migration of preview pictures")
      batch_size = 4

      l_query = Link.where("preview_url is not null").where("preview_url not like ''").
          where("preview_url not like '%size300x300%'")
      puts("#{l_query.count()} links have preview pics that need a migration")
      thread_array = nil
      while true do
        thread_array = []
        # Use a query string parameter to process the previews idempotent
        # Fetch items in blocks
        all_links = l_query.limit(batch_size)

        # Exit condition
        break if all_links.size == 0

        all_links.each do |a_link|
          thread_array << Thread.new { update_preview_for_link(a_link) }
        end

        # Join all threads together again
        thread_array.each do |t|
          t.join
        end
        puts "batch of links completed!"
      end
      puts "Data migration of preview pictures completed!"
    end

    def update_preview_for_link(l)
      unless l.preview_url_is_image? && l.preview_url.include?("http")
        puts "Cleaning up link_id: #{l.id} due to bad URL: #{l.preview_url}"
        l.preview_url = nil
        l.preview_attachment_id = nil
        save_if_valid l
        return
      end
      # Manually save each preview as an attachment by fetching it, storing it
      # formatting it, then uploading it S3 again. Latency intensive task!
      puts "Migrating link_id: #{l.id} and url: #{l.preview_url}"

      # Fetch image and serialize to disk
      filename = l.preview_url.split("/")[-1]
      # Had problems with PNG extensions before, making sure the extension is
      # therefore always lower case, no matter what!!!
      parts = filename.split(".")
      # Add a specific token into file to ensure idempotency
      filename = parts[0..-2].join(".") + "." + parts[-1].downcase
      extname = File.extname(filename)
      basename = File.basename(filename, extname)
      preview_file = Tempfile.new([basename, extname])
      preview_file.binmode

      begin
        # Fetch the file and write it to the disk
        preview_file << HTTParty.get(l.preview_url)

        # Use PaperClips configuration to resize and save to S3
        attachment = PreviewAttachment.new
        attachment.file = preview_file
        attachment.user = l.user
        attachment.save!
        # Update DB with the generated S3 link
        # Persist the new/updated URL in the Link object.
        l.preview_url = attachment.url
        l.preview_attachment_id = attachment.id
        save_if_valid l
      rescue
        # If something goes wrong, due to a bad URL etc. we just skipp this record
        puts "Processing preview image of link: #{l.id} failed!"
        l.preview_url = l.preview_url + "#size300x300"
        save_if_valid l
      ensure
        # Clean up - remove file
        preview_file.rewind
        preview_file.close true # close and delete/unlink the file
      end
    end

    def save_if_valid(l)
      puts "Validation for link_id: #{l.id} failed!" unless l.valid?
      l.save(validate: false)
    end
end
