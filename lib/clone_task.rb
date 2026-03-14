# frozen_string_literal: true

require 'active_record'

class CloneTask < ActiveRecord::Base
  validates :state, presence: true, inclusion: { in: %w[queued processing completed failed] }
  validates :message, presence: true
  validates :origin_inbox_message_id, presence: true
  validates :session_id, presence: true
  validates :session_start, presence: true
  validates :session_path, presence: true
  validates :log_path, presence: true
end
