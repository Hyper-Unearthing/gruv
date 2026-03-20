class CreateCloneTasksTable < ActiveRecord::Migration[8.1]
  def change
    create_table :clone_tasks do |t|
      t.string :state, null: false, default: 'queued'
      t.integer :pid
      t.text :message, null: false
      t.integer :origin_inbox_message_id, null: false
      t.text :result_message
      t.text :error_message
      t.string :session_id, null: false
      t.string :session_start, null: false
      t.string :session_path, null: false
      t.string :log_path, null: false
      t.string :started_at
      t.string :completed_at

      t.timestamps
    end

    add_index :clone_tasks, :state
    add_index :clone_tasks, :origin_inbox_message_id
    add_index :clone_tasks, :pid
  end
end
