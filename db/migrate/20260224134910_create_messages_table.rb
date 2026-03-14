class CreateMessagesTable < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.string :platform, null: false
      t.string :channel_id, null: false
      t.string :scope
      t.string :sender_id
      t.string :sender_username
      t.string :sender_name
      t.string :provider_message_id
      t.string :provider_update_id
      t.string :state, null: false, default: 'pending'
      t.integer :attempt_count, null: false, default: 0
      t.text :last_error
      t.string :processing_started_at
      t.string :processed_at
      t.text :message, null: false
      t.json :metadata, null: false, default: {}
      t.string :timestamp, null: false
    end

    add_index :messages, :state
    add_index :messages, :platform
    add_index :messages, [:platform, :channel_id]
    add_index :messages, [:platform, :sender_id, :timestamp], name: 'index_messages_on_platform_sender_timestamp'
    add_index :messages, :timestamp
    add_index :messages, [:platform, :channel_id, :provider_message_id], unique: true,
              where: 'provider_message_id IS NOT NULL',
              name: 'index_messages_on_platform_channel_provider_message'
  end
end
