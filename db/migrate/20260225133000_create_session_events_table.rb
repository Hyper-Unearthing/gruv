class CreateSessionEventsTable < ActiveRecord::Migration[8.1]
  def change
    create_table :session_events do |t|
      t.string :session_id, null: false
      t.string :session_start, null: false
      t.integer :position, null: false
      t.string :event_id, null: false
      t.string :parent_id
      t.string :timestamp, null: false
      t.string :event_type, null: false
      t.text :usage_json
      t.text :data_json, null: false
    end

    add_index :session_events, :event_id, unique: true
    add_index :session_events, [:session_id, :session_start, :position], unique: true, name: 'index_session_events_on_session_and_position'
    add_index :session_events, [:session_id, :session_start], name: 'index_session_events_on_session'
  end
end
