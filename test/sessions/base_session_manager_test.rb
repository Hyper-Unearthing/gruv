require 'minitest/autorun'
require_relative '../../lib/sessions/base_session_manager'
require_relative '../support/session_event_simulation_helper'

class BaseSessionManagerTest < Minitest::Test
  include SessionEventSimulationHelper

  def setup
    @manager = BaseSessionManager.new
  end

  def test_events_initialized_with_session
    events = @manager.send(:events)

    assert_equal 1, events.length
    assert_equal 'session', events.first[:type]
    refute_nil events.first[:id]
    refute_nil events.first[:timestamp]
  end

  def test_active_messages_and_model_input_without_compaction
    simulate_three_messages(
      @manager,
      user_text: 'find the bug',
      tool_id: 'toolu_pre_1',
      tool_name: 'read',
      tool_input: { path: 'lib/foo.rb' },
      tool_result: 'file contents'
    )

    expected_active_messages = [
      {
        role: 'user',
        content: [{ type: 'text', text: 'find the bug' }]
      },
      {
        role: 'assistant',
        content: [
          { type: 'text', text: 'I will inspect the file.' },
          { type: 'tool_use', id: 'toolu_pre_1', name: 'read', input: { path: 'lib/foo.rb' } }
        ]
      },
      {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: 'toolu_pre_1', content: 'file contents' }]
      }
    ]

    assert_equal expected_active_messages, @manager.active_messages
    assert_equal expected_active_messages, @manager.build_model_input_messages
  end

  def test_active_messages_and_model_input_with_compaction
    simulate_three_messages(
      @manager,
      user_text: 'find the bug',
      tool_id: 'toolu_pre_1',
      tool_name: 'read',
      tool_input: { path: 'lib/foo.rb' },
      tool_result: 'file contents'
    )

    @manager.push_entry(
      type: 'compaction',
      usage: { total_tokens: 123 },
      data: {
        summary: 'Compaction summary for previous conversation',
        first_kept_entry_id: 'ignored_for_this_test'
      }
    )

    simulate_three_messages(
      @manager,
      user_text: 'check stream behavior',
      tool_id: 'toolu_post_1',
      tool_name: 'bash',
      tool_input: { command: 'rg StreamOutputMapper lib' },
      tool_result: 'lib/llm_gateway_providers/openai_oauth/stream_output_mapper.rb'
    )

    expected_active_messages = [
      {
        role: 'user',
        content: [{ type: 'text', text: 'check stream behavior' }]
      },
      {
        role: 'assistant',
        content: [
          { type: 'text', text: 'I will inspect the file.' },
          { type: 'tool_use', id: 'toolu_post_1', name: 'bash', input: { command: 'rg StreamOutputMapper lib' } }
        ]
      },
      {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: 'toolu_post_1', content: 'lib/llm_gateway_providers/openai_oauth/stream_output_mapper.rb' }]
      }
    ]

    assert_equal expected_active_messages, @manager.active_messages
    assert_equal [
      {
        role: 'assistant',
        content: [{ type: 'text', text: 'Compaction summary for previous conversation' }]
      },
      *expected_active_messages
    ], @manager.build_model_input_messages
  end
end
