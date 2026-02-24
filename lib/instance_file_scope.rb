require 'fileutils'

module InstanceFileScope
  module_function

  def path(file_name)
    raise ArgumentError, 'file_name cannot be empty' if file_name.to_s.strip.empty?

    FileUtils.mkdir_p(instance_dir)
    File.join(instance_dir, File.basename(file_name))
  end

  def instance_dir
    File.expand_path('../instance', __dir__)
  end
end
