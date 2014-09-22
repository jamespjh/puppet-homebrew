require 'puppet/provider/package'

Puppet::Type.type(:package).provide(:brew, :parent => Puppet::Provider::Package) do
  BREW_CUSTOM_ENVIRONMENT = { "HOMEBREW_CACHE" => "/Library/Caches/Homebrew", "HOMEBREW_LOGS" => "/Library/Logs/Homebrew/", "HOMEBREW_NO_EMOJI" => "Yes" }
  desc "Package management using HomeBrew Cask on OS X"

  confine  :operatingsystem => :darwin

  has_feature :installable, :install_options
  has_feature :versionable
  has_feature :upgradeable
  has_feature :uninstallable

  commands :id   => "/usr/bin/id"
  commands :stat => "/usr/bin/stat"
  commands :sudo => "/usr/bin/sudo"
  commands :brew => "/usr/local/bin/brew"

  def self.execute(*cmd)
    owner = super([command(:stat), '-nf', '%Uu', command(:brew)]).to_i
    Puppet.debug "command owner is: #{owner}"
    if cmd[-1].is_a? Hash and cmd[-1].has_key? :custom_environment
        env = BREW_CUSTOM_ENVIRONMENT.merge(cmd.pop()[:custom_environment])
    else
        env = BREW_CUSTOM_ENVIRONMENT
    end
    if super([command(:id), '-u']).to_i.zero?
      Puppet.debug "running command in sudo environment as current user is root"
      super(cmd, :uid => owner, :failonfail => true, :combine => true, :custom_environment => env)
    else
      Puppet.debug "running command with current (non-root) user"
      super(cmd, :failonfail => true, :combine => true, :custom_environment => env)
    end
  end

  def execute(*args)
    self.class.execute(*args)
  end

  def linkapps?
    @resource[:linkapps] && @resource[:linkapps] == :true
  end

  def install_options
    Array(resource[:install_options]).flatten.compact
  end

  # Install packages, known as formulas, using brew.
  def install
    Puppet.notice "Installing #{@resource[:name]}"
    should = @resource[:ensure]
    package_name = @resource[:name]
    case should
    when true, false, Symbol
      # pass
    else
      package_name += "-#{should}"
    end
    Puppet.debug "  Package: #{package_name}"

    if install_options.any?
      output = execute([command(:brew), :cask, :install, package_name, *install_options])
    else
      output = execute([command(:brew), :cask, :install, package_name])
    end

    # Fail hard if there is no formula available.
    if output =~ /Error: No available formula/
      raise Puppet::ExecutionFailure, "Could not find package #{@resource[:name]}"
    end

    #if linkapps?
    #  output = execute([command(:brew), :linkapps])
    #end
  end

  def uninstall
    Puppet.notice "Uninstalling #{@resource[:name]}"
    begin
      execute([command(:brew), :cask,  :uninstall, @resource[:name]])
    rescue Puppet::ExecutionFailure
      Puppet.err "Package #{@resource[:name]} Uninstall failed: #{$!}"
      nil
    end
  end

  def update
    Puppet.notice "Updating #{@resource[:name]}"
    should = @resource[:ensure]
    package_name = @resource[:name]

    if installed?
      Puppet.notice "Unlinking #{package_name}"
      execute([command(:brew), :cask, :unlink, package_name, *install_options])
    end

    case should
    when true, false, Symbol
      # pass
    else
      package_name += "-#{should}"
    end
    Puppet.debug "  Package: #{package_name}"

    if install_options.any?
      output = execute([command(:brew), :cask, :install, package_name, *install_options])
    else
      output = execute([command(:brew), :cask, :install, package_name])
    end

    # Fail hard if there is no formula available.
    if output =~ /Error: No available formula/
      raise Puppet::ExecutionFailure, "Could not find package #{@resource[:name]}"
    end

    #if linkapps?
    #  output = execute([command(:brew), :linkapps])
    #end
  end

  def installed?
    is_not_installed = execute(
        command(:brew), :cask, :info, @resource[:name]
    ).split("\n").grep(/^Not installed$/).first
    is_not_installed.nil?
  end

  def query
    Puppet.debug "Querying #{@resource[:name]}"
    begin
      cellar_path = execute([command(:brew),:cask, '--cellar']).chomp
      Puppet.debug "Cellars path: #{cellar_path}"
      info = execute([command(:brew), :cask, :info, @resource[:name]]).split("\n").grep(/^#{cellar_path}/).first
      return nil if info.nil?
      version = info[%r{^#{cellar_path}/[^/]+/(\S+)}, 1]
      Puppet.debug "  Package #{@resource[:name]} is at version: #{version}.\n  info: #{info}"
      {
        :name     => @resource[:name],
        :ensure   => version,
        :provider => :cask
      }
    rescue Puppet::ExecutionFailure
      Puppet.err "Package #{@resource[:name]} Query failed: #{$!}"
      raise Puppet::Error, "Brew cask error: #{$!}"
    end
  end

  def latest
    Puppet.debug "Querying latest for #{@resource[:name]}"
    begin
      execpipe([command(:brew), :cask, :info, @resource[:name]]) do |process|
        process.each_line do |line|
          line.chomp!
          next if line.empty?
          next if line !~ /^#{@resource[:name]}:\s(.*)/i
          Puppet.debug "  Latest versions for #{@resource[:name]}: #{$1}"
          versions = $1
          #return 'HEAD' if versions =~ /\bHEAD\b/
          return $1 if versions =~ /stable (\d+[^\s]*)\s+\(bottled\)/
          return $1 if versions =~ /stable (\d+.*), HEAD/
          return $1 if versions =~ /stable (\d+.*)/
          return $1 if versions =~ /(\d+.*)/
        end
      end
      nil
    rescue Puppet::ExecutionFailure
      Puppet.err "Package #{@resource[:name]} Query Latest failed: #{$!}"
      nil
    end
  end

  def self.package_list(options={})
    Puppet.debug "Listing currently installed casks"
    brew_list_command = [command(:brew), :cask, "list", "--versions"]

    if name = options[:justme]
      brew_list_command << name
    end

    begin
      list = execute(brew_list_command).
        lines.
        map {|line| name_version_split(line) }
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not list packages: #{detail}"
    end

    if options[:justme]
      return list.shift
    else
      return list
    end
  end

  def self.name_version_split(line)
    info    = line.split(' ')
    name    = info[0]
    version = info.last
    Puppet.debug "  Package #{name} is at version: #{version}."
    {
      :name     => name,
      :ensure   => version,
      :provider => :cask
    }
  end

  def self.instances
    Puppet.debug "Listing currently installed casks"
    package_list.collect { |hash| new(hash) }
  end
end
