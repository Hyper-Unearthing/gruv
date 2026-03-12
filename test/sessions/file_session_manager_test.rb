require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'llm_gateway'
require_relative '../../lib/sessions/file_session_manager'
require_relative '../../lib/compaction_prompt'
require_relative '../support/session_event_simulation_helper'

class FileSessionManagerNormalizePathTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    # Instantiate with an absolute tmp path so initialize doesn't touch real dirs
    @manager = FileSessionManager.new(File.join(@tmpdir, 'session.jsonl'))
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_bare_filename_uses_session_dir
    result = @manager.normalize_path('test.jsonl')
    assert_equal File.join(session_dir, 'test.jsonl'), result
  end

  def test_relative_path_with_parent_traversal
    Dir.chdir(@tmpdir) do
      result = @manager.normalize_path('../test.jsonl')
      assert_equal File.expand_path('../test.jsonl'), result
    end
  end

  def test_relative_path_with_subdirectory
    Dir.chdir(@tmpdir) do
      result = @manager.normalize_path('./subdir/test.jsonl')
      assert_equal File.expand_path('./subdir/test.jsonl'), result
    end
  end

  def test_absolute_path_is_returned_as_is
    path = File.join(@tmpdir, 'absolute', 'test.jsonl')
    result = @manager.normalize_path(path)
    assert_equal path, result
  end

  private

  def session_dir
    @manager.send(:session_dir)
  end
end

class FileSessionManagerEventsTest < Minitest::Test
  include SessionEventSimulationHelper

  def setup
    @tmpdir = Dir.mktmpdir
    @session_path = File.join(@tmpdir, 'session.jsonl')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_simulated_three_messages_are_persisted_to_file
    manager = FileSessionManager.new(@session_path)

    simulate_three_messages(
      manager,
      user_text: 'find the bug',
      tool_id: 'toolu_1',
      tool_name: 'read',
      tool_input: { path: 'lib/foo.rb' },
      tool_result: 'file contents'
    )

    persisted_entries = File.readlines(@session_path).flat_map { |line| JSON.parse(line, symbolize_names: true) }

    assert_equal 4, persisted_entries.length
    assert_equal 'session', persisted_entries[0][:type]
    assert_equal 'message', persisted_entries[1][:type]
    assert_equal 'message', persisted_entries[2][:type]
    assert_equal 'message', persisted_entries[3][:type]

    assert_equal 'find the bug', persisted_entries[1].dig(:data, :content, 0, :text)
    assert_equal 'toolu_1', persisted_entries[2].dig(:data, :content, 1, :id)
    assert_equal 'file contents', persisted_entries[3].dig(:data, :content, 0, :content)
  end

  def test_loading_compacted_file_keeps_all_events_and_active_messages_from_last_block
    fixture_path = File.expand_path('file_session_manager_compaction_fixture.jsonl', __dir__)
    manager = FileSessionManager.new(fixture_path)

    assert_equal 8, manager.events.length

    expected_last_three = [
      {
        role: 'user',
        content: [{ type: 'text', text: 'post user question' }]
      },
      {
        role: 'assistant',
        content: [
          { type: 'text', text: 'post assistant tool call' },
          { type: 'tool_use', id: 'toolu_post_1', name: 'bash', input: { command: 'rg StreamOutputMapper lib' } }
        ]
      },
      {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: 'toolu_post_1', content: 'lib/llm_gateway_providers/openai_oauth/stream_output_mapper.rb' }]
      }
    ]

    assert_equal expected_last_three, manager.active_messages
    assert_equal [
      {
        role: 'assistant',
        content: [{ type: 'text', text: 'compacted summary' }]
      },
      *expected_last_three
    ], manager.build_model_input_messages
  end

  def test_compaction_reads_fixture_and_calls_client_chat_with_expected_parameters
    fixture_path = File.expand_path('file_session_manager_compaction_fixture.jsonl', __dir__)

    Dir.mktmpdir do |dir|
      session_path = File.join(dir, 'session.jsonl')
      FileUtils.cp(fixture_path, session_path)

      manager = FileSessionManager.new(session_path)

      client = Object.new
      client.define_singleton_method(:chat) do |messages, tools:, system:|
        raise 'expected tools to be []' unless tools == []
        raise 'expected a single user message prompt' unless messages.length == 1
        raise 'expected system prompt' unless system.length == 1

        prompt_text = messages[0].dig(:content, 0, :text)
        raise 'missing previous summary in prompt' unless prompt_text.include?('compacted summary')

        transcript_json = prompt_text[/<transcript>\n(.*)\n<\/transcript>/m, 1]
        transcript = JSON.parse(transcript_json, symbolize_names: true)

        expected_transcript = [
          {
            role: 'user',
            content: [{ type: 'text', text: 'post user question' }]
          },
          {
            role: 'assistant',
            content: [
              { type: 'text', text: 'post assistant tool call' },
              { type: 'tool_use', id: 'toolu_post_1', name: 'bash', input: { command: 'rg StreamOutputMapper lib' } }
            ]
          },
          {
            role: 'user',
            content: [{ type: 'tool_result', tool_use_id: 'toolu_post_1', content: 'lib/llm_gateway_providers/openai_oauth/stream_output_mapper.rb' }]
          }
        ]

        raise 'unexpected transcript payload' unless transcript == expected_transcript

        {
          usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 },
          choices: [
            {
              content: [
                { type: 'text', text: "# Topic\n- Compacted" }
              ]
            }
          ]
        }
      end

      compaction_entry = manager.compaction(client)

      assert_equal 'compaction', compaction_entry[:type]
      assert_equal "# Topic\n- Compacted", compaction_entry.dig(:data, :summary)
      assert_equal 9, manager.events.length
      assert_equal 'compaction', manager.events.last[:type]
    end
  end

end
