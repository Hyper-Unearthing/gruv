class CreateContactsTable < ActiveRecord::Migration[8.1]
  def change
    create_table :contacts do |t|
      t.string :name
      t.string :telegram_chat_id, null: false
      t.text :tags
      t.text :notes
      t.text :user_requests
      t.timestamps
    end

    add_index :contacts, :telegram_chat_id, unique: true
  end
end
