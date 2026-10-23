# frozen_string_literal: true

class CreateFeatureAnnouncementCampaigns < ActiveRecord::Migration[7.1]
  PIRACY_REPORTS_BODY = <<~HTML
    <p>Hi creator,</p>
    <p>Found a pirated copy of your product? You can now report it from Gumroad.</p>
    <p>We check the page and prepare a takedown notice. You review and sign it before we send it to the site.</p>
    <p>Choose <strong>Report piracy</strong> from your product’s menu on the <a href="https://gumroad.com/products">Products page</a>.</p>
    <p>You can submit up to five reports each calendar month. <a href="https://gumroad.com/help/article/354-reporting-piracy">Read the guide</a> for the requirements and what happens next.</p>
    <p>If you try it, reply to this email with what worked and what we should improve.</p>
    <p>The Gumroad team</p>
  HTML

  def up
    create_table :feature_announcement_campaigns do |t|
      t.string :key, limit: 64, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.string :reply_to, null: false
      t.string :audience, limit: 64, null: false
      t.string :state, limit: 16, null: false
      t.string :content_digest, limit: 64
      t.bigint :approved_by_id
      t.datetime :approved_at
      t.timestamps

      t.index :key, unique: true
    end

    # The copy that used to live in FeatureAnnouncementMailer::CAMPAIGNS, so queued jobs keep
    # their campaign. The digest matches FeatureAnnouncementCampaign.digest_for.
    subject = "Report piracy from Gumroad"
    reply_to = "support@gumroad.com"
    digest = Digest::SHA256.hexdigest([subject, PIRACY_REPORTS_BODY, reply_to].to_json)
    now = quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO feature_announcement_campaigns
        (`key`, subject, body, reply_to, audience, state, content_digest, approved_at, created_at, updated_at)
      VALUES
        ('piracy_reports', #{quote(subject)}, #{quote(PIRACY_REPORTS_BODY)}, #{quote(reply_to)}, 'piracy_reports', 'sent', #{quote(digest)}, #{now}, #{now}, #{now})
    SQL
  end

  def down
    drop_table :feature_announcement_campaigns
  end
end
