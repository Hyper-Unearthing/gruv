require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../lib/communication_platform/telegram/poller'

class TelegramPollerTest < Minitest::Test
  class FakeInbox
    attr_reader :inserted_messages

    def initialize
      @inserted_messages = []
    end

    def insert_message(**payload)
      @inserted_messages << payload
    end
  end

  class TestTelegramPoller < CommunicationPlatform::Telegram::Poller
    private

    def resolve_token
      'test-token'
    end

    def load_state
      { offset: 0, pending_media_groups: {} }
    end

    def persist_state
      nil
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir('telegram-poller-test')
    @poller = TestTelegramPoller.new(File.join(@tmpdir, 'test.sqlite3'))
    @fake_inbox = FakeInbox.new
    @poller.instance_variable_set(:@inbox, @fake_inbox)

    @poller.define_singleton_method(:download_photos) do |photo_entries|
      Array(photo_entries).filter_map do |entry|
        file_id = entry['file_id']
        next if file_id.nil? || file_id.empty?

        { type: 'image', file_id: file_id, path: "/tmp/#{file_id}.jpg" }
      end
    end

    @poller.define_singleton_method(:download_message_attachments) do |message|
      document = message['document']
      if document
        [{
          type: 'document',
          file_id: document['file_id'],
          file_name: document['file_name'],
          path: "/tmp/#{document['file_id']}.bin"
        }]
      else
        []
      end
    end
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def test_media_group_updates_flush_as_one_grouped_inbox_message
    update_one = {
      'update_id' => 101,
      'message' => {
        'message_id' => 201,
        'media_group_id' => 'album-1',
        'caption' => 'album caption',
        'chat' => { 'id' => 555, 'type' => 'private' },
        'from' => { 'id' => 42, 'username' => 'alice', 'first_name' => 'Alice' },
        'photo' => [{ 'file_id' => 'photo-1', 'file_size' => 100 }]
      }
    }

    update_two = {
      'update_id' => 102,
      'message' => {
        'message_id' => 202,
        'media_group_id' => 'album-1',
        'chat' => { 'id' => 555, 'type' => 'private' },
        'from' => { 'id' => 42, 'username' => 'alice', 'first_name' => 'Alice' },
        'document' => { 'file_id' => 'doc-1', 'file_name' => 'notes.txt' }
      }
    }

    @poller.send(:process_update, update_one)
    @poller.send(:process_update, update_two)

    assert_empty @fake_inbox.inserted_messages
    assert_equal 1, @poller.instance_variable_get(:@pending_media_groups).length

    @poller.send(:flush_ready_media_groups!, force: true)

    assert_equal 1, @fake_inbox.inserted_messages.length

    inserted = @fake_inbox.inserted_messages.first
    metadata = inserted[:metadata]

    assert_equal 'telegram', inserted[:platform]
    assert_equal '555', inserted[:channel_id]
    assert_equal 'dm', inserted[:scope]
    assert_equal 'media_group:album-1', inserted[:provider_message_id]
    assert_equal 102, inserted[:provider_update_id]
    assert_equal 'album caption', inserted[:message]

    assert_equal true, metadata[:is_media_group]
    assert_equal 'album-1', metadata[:media_group_id]
    assert_equal 2, metadata[:media_group_item_count]
    assert_equal [201, 202], metadata[:media_group_message_ids]
    assert_equal [101, 102], metadata[:media_group_update_ids]
    assert_equal ['photo-1'], metadata[:photo_file_ids]
    assert_equal ['/tmp/photo-1.jpg'], metadata[:image_file_paths]
    assert_equal ['/tmp/doc-1.bin'], metadata[:attachment_file_paths]
    assert_equal 'document', metadata[:attachment_files].first[:type]
    assert_equal [201, 202], metadata[:media_group_items].map { |item| item[:message_id] }

    assert_empty @poller.instance_variable_get(:@pending_media_groups)
  end

  def test_non_album_updates_still_insert_immediately
    update = {
      'update_id' => 301,
      'message' => {
        'message_id' => 401,
        'caption' => 'single photo',
        'chat' => { 'id' => 777, 'type' => 'private' },
        'from' => { 'id' => 84, 'username' => 'bob', 'first_name' => 'Bob' },
        'photo' => [{ 'file_id' => 'photo-2', 'file_size' => 200 }]
      }
    }

    @poller.send(:process_update, update)

    assert_equal 1, @fake_inbox.inserted_messages.length

    inserted = @fake_inbox.inserted_messages.first
    metadata = inserted[:metadata]

    assert_equal '401', inserted[:provider_message_id].to_s
    assert_equal 'single photo', inserted[:message]
    assert_equal 401, metadata[:message_id]
    assert_equal 401, metadata[:provider_message_id]
    refute metadata[:is_media_group]
  end
end
