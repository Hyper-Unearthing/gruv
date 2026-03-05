require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../lib/sessions/file_session_manager'

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
