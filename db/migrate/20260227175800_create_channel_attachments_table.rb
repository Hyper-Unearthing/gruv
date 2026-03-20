class CreateChannelAttachmentsTable < ActiveRecord::Migration[8.1]
  def change
    create_table :channel_attachments do |t|
      t.integer :message_id, null: false
      t.string :source, null: false
      t.string :channel_id, null: false
      t.string :provider_message_id
      t.string :attachment_type, null: false
      t.string :provider_file_id
      t.string :file_name
      t.string :content_type
      t.string :url
      t.string :path, null: false
      t.string :timestamp, null: false
    end

    add_index :channel_attachments, :message_id
    add_index :channel_attachments, [:source, :channel_id]
    add_index :channel_attachments, :provider_message_id
    add_index :channel_attachments, :timestamp
    add_index :channel_attachments, :path, unique: true
  end
end
