#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'base64'
require 'time'
require 'sqlite3'
require 'llm_gateway'
require_relative '../tools'

ROOT = File.expand_path('..', __dir__)
INSTANCE_DIR = File.join(ROOT, 'instance')
CONFIG_PATH = File.join(INSTANCE_DIR, 'config.json')
DB_PATH = File.join(INSTANCE_DIR, 'gruv.sqlite3')

class ManualToolTest
  def run
    puts "== Manual tool smoke test =="
    puts "root: #{ROOT}"

    config = read_config
    telegram_dm = find_telegram_dm
    discord_dm = find_discord_dm
    sample_photo = find_sample_photo

    puts "config_path: #{CONFIG_PATH}"
    puts "config_keys: #{config.keys.sort.join(', ')}"
    puts "telegram_dm_channel: #{telegram_dm || '(none found)'}"
    puts "discord_dm_channel: #{discord_dm || '(none found)'}"
    puts "sample_photo: #{sample_photo || '(none found)'}"
    puts

    run_case('ReadTool') do
      ReadTool.new.execute(path: 'instance/config.json')
    end

    run_case('BashTool') do
      BashTool.new.execute(command: 'pwd')
    end

    run_case('SqlTool') do
      SqlTool.new.execute(query: <<~SQL)
        select platform, count(*) as count
        from messages
        group by platform
        order by platform;
      SQL
    end

    tmp_file = 'tmp/manual_tool_test.txt'
    run_case('WriteTool') do
      WriteTool.new.execute(path: tmp_file, content: "manual tool test\n")
    end

    run_case('EditTool') do
      EditTool.new.execute(path: tmp_file, oldText: "manual tool test\n", newText: "manual tool test (edited)\n")
    end

    run_case('GetMeTool telegram') do
      GetMeTool.new.execute(platform: 'telegram')
    end

    run_case('GetMeTool discord') do
      GetMeTool.new.execute(platform: 'discord')
    end

    if telegram_dm
      run_case('SendMessageTool telegram') do
        SendMessageTool.new.execute(
          platform: 'telegram',
          channel_id: telegram_dm,
          message: "gruv manual tool test #{Time.now.utc.iso8601}"
        )
      end

      if sample_photo
        run_case('SendPhotoTool telegram') do
          SendPhotoTool.new.execute(
            platform: 'telegram',
            channel_id: telegram_dm,
            photo: sample_photo,
            caption: 'gruv manual photo test (telegram)'
          )
        end
      end

      run_case('SendVoiceTool telegram') do
        SendVoiceTool.new.execute(
          platform: 'telegram',
          channel_id: telegram_dm,
          voice: fake_ogg_base64,
          caption: 'gruv manual voice test (telegram)'
        )
      end

      run_case('SendDocumentTool telegram') do
        SendDocumentTool.new.execute(
          platform: 'telegram',
          channel_id: telegram_dm,
          document: 'README.md',
          caption: 'gruv manual document test (telegram)'
        )
      end
    else
      puts '[SKIP] Telegram send tools: no DM channel found in database'
    end

    if discord_dm
      run_case('SendMessageTool discord') do
        SendMessageTool.new.execute(
          platform: 'discord',
          channel_id: discord_dm,
          message: "gruv manual tool test #{Time.now.utc.iso8601}"
        )
      end

      if sample_photo
        run_case('SendPhotoTool discord') do
          SendPhotoTool.new.execute(
            platform: 'discord',
            channel_id: discord_dm,
            photo: sample_photo,
            caption: 'gruv manual photo test (discord)'
          )
        end
      end

      run_case('SendVoiceTool discord') do
        SendVoiceTool.new.execute(
          platform: 'discord',
          channel_id: discord_dm,
          voice: fake_ogg_base64,
          caption: 'gruv manual voice test (discord)'
        )
      end

      run_case('SendDocumentTool discord') do
        SendDocumentTool.new.execute(
          platform: 'discord',
          channel_id: discord_dm,
          document: 'README.md',
          caption: 'gruv manual document test (discord)'
        )
      end
    else
      puts '[SKIP] Discord send tools: no DM channel found in database'
    end
  end

  private

  def read_config
    return {} unless File.exist?(CONFIG_PATH)

    JSON.parse(File.read(CONFIG_PATH))
  rescue JSON::ParserError
    {}
  end

  def find_telegram_dm
    db = SQLite3::Database.new(DB_PATH)
    row = db.get_first_row(<<~SQL)
      select channel_id
      from messages
      where platform = 'telegram'
      and json_extract(metadata, '$.chat_type') = 'private'
      order by id desc
      limit 1;
    SQL
    row && row[0]
  ensure
    db&.close
  end

  def find_discord_dm
    db = SQLite3::Database.new(DB_PATH)
    row = db.get_first_row(<<~SQL)
      select channel_id
      from messages
      where platform = 'discord'
      and json_extract(metadata, '$.guild_id') is null
      order by id desc
      limit 1;
    SQL
    row && row[0]
  ensure
    db&.close
  end

  def find_sample_photo
    candidates = Dir[File.join(INSTANCE_DIR, 'photos', '*')].sort.reverse
    candidates += Dir[File.join(INSTANCE_DIR, 'discord_attachments', '*')].sort.reverse
    candidates.find { |path| path.match?(/\.(jpg|jpeg|png|webp|gif)$/i) }
  end

  def fake_ogg_base64
    # Minimal Ogg-like bytes so SendVoice tool gets exercised even without a real voice file.
    "base64:#{Base64.strict_encode64("OggS\x00" + ("\x00" * 64))}"
  end

  def run_case(name)
    puts "--- #{name} ---"
    result = yield
    puts pretty(result)
    puts
  rescue StandardError => e
    puts "ERROR: #{e.class}: #{e.message}"
    puts
  end

  def pretty(result)
    case result
    when String
      begin
        JSON.pretty_generate(JSON.parse(result))
      rescue JSON::ParserError
        result
      end
    else
      JSON.pretty_generate(result)
    end
  end
end

ManualToolTest.new.run
