require "colorize"

module GWT
  VERSION = "0.1.0"

  def self.run(args = ARGV)
    subcommand = args.shift?

    case subcommand
    when "clone"
      clone_args, other_args = args.partition { |arg| arg.starts_with? '-' }

      unless other_args.size == 2
        raise "unknown args, expected path and URL"
      end
      base_path, url = other_args

      clone(base_path, url, clone_args)
    when "branch", "b"
      raise "unknown args, expected branch name" unless args.size == 1

      branch(args.first)
    when "feature"
      raise "unknown args, expected feature branch name" unless args.size == 1

      branch("feature/#{args.first}")
    when "bugfix", "bug"
      raise "unknown args, expected bugfix branch name" unless args.size == 1

      branch("bugfix/#{args.first}")
    when "ls"
      ls
    else
      raise "subcommands: clone, branch, feature, bugfix"
    end
  rescue ex : GWT::Error
    STDERR << "Error".colorize.red << ": #{ex.message}\n"
    exit 1
  end

  def self.clone(base_path, url, clone_args)
    clone_dir = "#{base_path}/master"

    git_args = ["clone"]
    git_args += clone_args
    git_args << url
    git_args << clone_dir

    command("git", git_args)

    default_branch = command_output("git", ["symbolic-ref", "--short", "HEAD"], chdir: clone_dir)
    File.rename(clone_dir, "#{base_path}/#{default_branch}")

    File.touch("#{base_path}/.gwt-root")
  end

  def self.branch(branch_name)
    target_dir = "#{root_dir}/#{branch_name}"

    command("git", ["worktree", "add", "-b", branch_name, target_dir]) unless Dir.exists? target_dir

    puts target_dir
  end

  def self.ls
    command("git", ["worktree", "prune"])

    root_dir = self.root_dir + "/"
    command_output("git", ["worktree", "list"]).each_line do |line|
      STDERR.puts line.lchop(root_dir)
    end
  end

  def self.root_dir : String
    dir = Dir.current
    until File.exists? "#{dir}/.gwt-root"
      dir = File.expand_path("..", dir)

      raise "not in GWT root" if dir == "/"
    end

    dir
  end

  def self.command_output(command : String, args = nil,
                          env : Process::Env = nil, clear_env : Bool = false,
                          shell : Bool = false,
                          input : Process::Stdio = Process::Redirect::Close, error : Process::Stdio = Process::Redirect::Inherit,
                          chdir : String? = nil,
                          allow_failure : Bool = false)
    String.build do |str|
      command(command, args, env, clear_env, shell, input, str, error, chdir, allow_failure)
    end.chomp
  end

  def self.command(command : String, args = nil,
                   env : Process::Env = nil, clear_env : Bool = false,
                   shell : Bool = false,
                   input : Process::Stdio = Process::Redirect::Inherit, output : Process::Stdio = STDERR, error : Process::Stdio = Process::Redirect::Inherit,
                   chdir : String? = nil,
                   allow_failure : Bool = false) : Process::Status
    STDERR << "Running".colorize.blue << ": #{command} #{args.inspect}\n"

    status = Process.run(command, args, env, clear_env, shell, input, output, error, chdir)
    raise "Command failed! Exit code #{status.exit_code}" unless allow_failure || status.success?

    status
  end

  class Error < Exception
  end

  def self.raise(message)
    ::raise GWT::Error.new(message)
  end
end
